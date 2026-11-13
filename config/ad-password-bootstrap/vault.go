package main

import (
	"bytes"
	"crypto/tls"
	"crypto/x509"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"net/url"
	"os"
	"strings"
	"time"
)

type vaultClient struct {
	address   string
	namespace string
	token     string
	http      *http.Client
}

func loginVault(role string) (*vaultClient, error) {
	address := strings.TrimRight(os.Getenv("AD_BOOTSTRAP_VAULT_ADDR"), "/")
	origin, err := url.Parse(address)
	if err != nil || origin.Scheme != "https" || origin.Hostname() == "" || origin.User != nil ||
		origin.Path != "" || origin.RawQuery != "" || origin.ForceQuery || origin.Fragment != "" || origin.Opaque != "" {
		return nil, errors.New("AD_BOOTSTRAP_VAULT_ADDR must be a Vault HTTPS origin")
	}
	pem, err := os.ReadFile(os.Getenv("AD_BOOTSTRAP_VAULT_CACERT"))
	roots := x509.NewCertPool()
	if err != nil || !roots.AppendCertsFromPEM(pem) {
		return nil, errors.New("AD_BOOTSTRAP_VAULT_CACERT must point to a valid PEM CA file")
	}
	jwt := os.Getenv(jwtVar)
	if jwt == "" {
		return nil, errors.New("missing GitLab ID token")
	}
	transport := http.DefaultTransport.(*http.Transport).Clone()
	transport.Proxy = nil
	transport.TLSClientConfig = &tls.Config{RootCAs: roots, MinVersion: tls.VersionTLS12}
	client := &vaultClient{
		address: address, namespace: os.Getenv("AD_BOOTSTRAP_VAULT_NAMESPACE"),
		http: &http.Client{
			Transport: transport, Timeout: 15 * time.Second,
			CheckRedirect: func(*http.Request, []*http.Request) error { return http.ErrUseLastResponse },
		},
	}
	var result struct {
		Auth struct {
			Token string `json:"client_token"`
		} `json:"auth"`
	}
	status, err := client.request(http.MethodPost, "auth/gitlab-jwt/login", map[string]string{"role": role, "jwt": jwt}, &result)
	if err != nil {
		return nil, fmt.Errorf("Vault JWT login: %w", err)
	}
	if status != http.StatusOK || result.Auth.Token == "" {
		return nil, fmt.Errorf("Vault JWT login did not return a token (HTTP %d)", status)
	}
	client.token = result.Auth.Token
	return client, nil
}

func (v *vaultClient) request(method, path string, payload, result any) (int, error) {
	var body io.Reader
	if payload != nil {
		data, err := json.Marshal(payload)
		if err != nil {
			return 0, errors.New("cannot encode Vault request")
		}
		body = bytes.NewReader(data)
	}
	req, err := http.NewRequest(method, v.address+"/v1/"+path, body)
	if err != nil {
		return 0, errors.New("cannot prepare Vault request")
	}
	if payload != nil {
		req.Header.Set("Content-Type", "application/json")
	}
	if v.token != "" {
		req.Header.Set("X-Vault-Token", v.token)
	}
	if v.namespace != "" {
		req.Header.Set("X-Vault-Namespace", v.namespace)
	}
	resp, err := v.http.Do(req)
	if err != nil {
		return 0, errors.New("Vault request failed. Check runner connectivity and TLS")
	}
	defer resp.Body.Close()
	if resp.StatusCode == http.StatusOK && result != nil {
		if json.NewDecoder(io.LimitReader(resp.Body, 1<<20)).Decode(result) != nil {
			return resp.StatusCode, errors.New("invalid Vault response")
		}
	} else {
		_, _ = io.Copy(io.Discard, io.LimitReader(resp.Body, 1<<20))
	}
	return resp.StatusCode, nil
}

func (v *vaultClient) readPassword(path string) (string, int, error) {
	var result struct {
		Data struct {
			Data     map[string]string `json:"data"`
			Metadata struct {
				Version int `json:"version"`
			} `json:"metadata"`
		} `json:"data"`
	}
	status, err := v.request(http.MethodGet, path+"?version=1", nil, &result)
	password := result.Data.Data["password"]
	if err == nil && status == http.StatusOK && (password == "" || result.Data.Metadata.Version != 1) {
		err = errors.New("Vault returned an invalid initial password")
	}
	return password, status, err
}

func (v *vaultClient) initialPassword(prefix, policy, key string, create bool) (string, error) {
	path := "ad-bootstrap/data/" + prefix + "/" + key
	password, status, err := v.readPassword(path)
	if err != nil {
		return "", err
	}
	if status == http.StatusNotFound && create {
		var generated struct {
			Data map[string]string `json:"data"`
		}
		status, err = v.request(http.MethodGet, "sys/policies/password/"+policy+"/generate", nil, &generated)
		if err != nil {
			return "", err
		}
		if status != http.StatusOK || generated.Data["password"] == "" {
			return "", fmt.Errorf("Vault password generation failed (HTTP %d)", status)
		}
		payload := map[string]any{"options": map[string]int{"cas": 0}, "data": generated.Data}
		status, err = v.request(http.MethodPost, path, payload, nil)
		if err != nil {
			return "", err
		}
		// A concurrent writer may win the CAS check or make the key require update access.
		switch status {
		case http.StatusOK, http.StatusNoContent, http.StatusBadRequest, http.StatusForbidden:
			password, status, err = v.readPassword(path)
			if err != nil {
				return "", err
			}
		default:
			return "", fmt.Errorf("Vault could not create the password for %q (HTTP %d)", key, status)
		}
	}
	if status != http.StatusOK {
		return "", fmt.Errorf("Vault password for %q is unavailable (HTTP %d)", key, status)
	}
	return password, nil
}
