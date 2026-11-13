package main

import (
	"encoding/json"
	"fmt"
	"net/http"
	"net/http/httptest"
	"slices"
	"strings"
	"testing"
)

func TestBatchAndFirstState(t *testing.T) {
	tracked, err := trackedUsers(nil)
	if err != nil || len(tracked) != 0 {
		t.Fatalf("empty state: %v %v", tracked, err)
	}
	state := `{"resources":[{"module":"module.directory","mode":"managed","type":"ad_user","name":"directory","instances":[{"index_key":"old"},{"index_key":"deposed","deposed":"id"}]}]}`
	tracked, err = trackedUsers([]byte(state))
	if err != nil || !tracked["old"] || tracked["deposed"] {
		t.Fatalf("tracked state: %v %v", tracked, err)
	}
	inventory := map[string]*user{"old": {Enabled: true}, "manual": {Enabled: true}, "new-b": {Enabled: true}, "new-a": {Enabled: true}, "disabled": {}}
	got := newPasswordKeys(inventory, tracked, map[string]string{"manual": "override"})
	if !slices.Equal(got, []string{"new-a", "new-b"}) {
		t.Fatalf("selected users: %v", got)
	}
	plan := `{"resource_changes":[{"module_address":"module.directory","mode":"managed","type":"ad_user","name":"directory","index":"new-a","change":{"actions":["create"]}}]}`
	if verifyPlan([]byte(plan), inventory, nil) == nil || verifyPlan([]byte(plan), inventory, map[string]string{"new-a": "example"}) != nil {
		t.Fatal("plan guard did not enforce initial password")
	}
}

func TestVaultBatchRetryAndReadOnlyApply(t *testing.T) {
	passwords := map[string]string{}
	generated := 0
	server := httptest.NewTLSServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.Header.Get("X-Vault-Token") != "token" || r.Header.Get("X-Vault-Namespace") != "test" {
			w.WriteHeader(http.StatusForbidden)
			return
		}
		if strings.HasSuffix(r.URL.Path, "/generate") {
			generated++
			fmt.Fprintf(w, `{"data":{"password":"generated-%d"}}`, generated)
			return
		}
		if r.Method == http.MethodPost {
			var payload struct {
				Options map[string]int
				Data    map[string]string
			}
			if json.NewDecoder(r.Body).Decode(&payload) != nil || payload.Options["cas"] != 0 {
				w.WriteHeader(http.StatusBadRequest)
				return
			}
			if strings.HasSuffix(r.URL.Path, "/race") {
				passwords[r.URL.Path] = "winner"
				w.WriteHeader(http.StatusForbidden)
				return
			}
			passwords[r.URL.Path] = payload.Data["password"]
			w.WriteHeader(http.StatusNoContent)
			return
		}
		if r.URL.Query().Get("version") != "1" {
			w.WriteHeader(http.StatusBadRequest)
			return
		}
		if password := passwords[r.URL.Path]; password != "" {
			fmt.Fprintf(w, `{"data":{"data":{"password":%q},"metadata":{"version":1}}}`, password)
			return
		}
		w.WriteHeader(http.StatusNotFound)
	}))
	defer server.Close()
	client := &vaultClient{address: server.URL, token: "token", namespace: "test", http: server.Client()}
	for i, key := range []string{"one", "two", "race"} {
		first, err := client.initialPassword("projects/1/production", "policy", key, true)
		want := fmt.Sprintf("generated-%d", i+1)
		if key == "race" {
			want = "winner"
		}
		if err != nil || first != want {
			t.Fatalf("initial %s: %v", key, err)
		}
		for _, create := range []bool{true, false} {
			next, err := client.initialPassword("projects/1/production", "policy", key, create)
			if err != nil || next != first {
				t.Fatalf("retry %s: %v", key, err)
			}
		}
	}
	if _, err := client.initialPassword("projects/1/production", "policy", "missing", false); err == nil || generated != 3 {
		t.Fatalf("read-only apply generated a password or failed to reject missing secret; generated=%d", generated)
	}
}
