package main

import (
	"bytes"
	"encoding/base64"
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"os/exec"
	"regexp"
	"slices"
	"strings"
	"syscall"
)

const (
	planFile     = "deployment.tfplan"
	manifestFile = "ad-bootstrap-users.json"
	passwordVar  = "TF_VAR_ad_user_passwords"
	jwtVar       = "AD_BOOTSTRAP_VAULT_JWT"
)

var (
	projectPattern     = regexp.MustCompile("^[1-9][0-9]*$")
	environmentPattern = regexp.MustCompile("^[a-z][a-z0-9-]*$")
	keyPattern         = regexp.MustCompile("^[a-z0-9][a-z0-9_-]*$")
)

type user struct {
	Enabled               bool  `json:"enabled"`
	ChangePasswordAtLogon *bool `json:"change_password_at_logon"`
}

func (u user) needsPassword() bool {
	return u.Enabled || (u.ChangePasswordAtLogon != nil && !*u.ChangePasswordAtLogon)
}

type manifest struct {
	Prefix string   `json:"prefix"`
	Users  []string `json:"users"`
}

type resource struct {
	Mode string `json:"mode"`
	Type string `json:"type"`
	Name string `json:"name"`
}

func (r resource) isDirectoryUser(module string) bool {
	return module == "module.directory" && r.Mode == "managed" && r.Type == "ad_user" && r.Name == "directory"
}

func terraformOutput(env []string, input string, args ...string) ([]byte, error) {
	cmd := exec.Command("terraform", args...)
	cmd.Env = env
	cmd.Stdin = strings.NewReader(input)
	return cmd.Output()
}

func readInventory(env []string) (map[string]*user, error) {
	const expression = `base64encode(jsonencode(yamldecode(file("${local.inventory_directory}/users.yaml"))))`
	output, err := terraformOutput(env, expression+"\n", "console", "-no-color")
	if err != nil {
		return nil, errors.New("cannot read the AD inventory through terraform console. Check YAML and backend")
	}
	var encoded string
	if json.Unmarshal(output, &encoded) != nil {
		return nil, errors.New("unexpected Terraform inventory output")
	}
	data, err := base64.StdEncoding.DecodeString(encoded)
	var inventory map[string]*user
	if err != nil || json.Unmarshal(data, &inventory) != nil || inventory == nil {
		return nil, errors.New("expected a map of AD users in users.yaml")
	}
	for _, entry := range inventory {
		if entry == nil {
			return nil, errors.New("expected an object for every user in users.yaml")
		}
	}
	return inventory, nil
}

func trackedUsers(output []byte) (map[string]bool, error) {
	tracked := make(map[string]bool)
	if len(bytes.TrimSpace(output)) == 0 {
		return tracked, nil
	}
	var state struct {
		Resources []struct {
			resource
			Module    string `json:"module"`
			Instances []struct {
				Key     json.RawMessage `json:"index_key"`
				Deposed string          `json:"deposed"`
			} `json:"instances"`
		} `json:"resources"`
	}
	if json.Unmarshal(output, &state) != nil || state.Resources == nil {
		return nil, errors.New("unexpected AD Terraform state")
	}
	for _, entry := range state.Resources {
		if !entry.isDirectoryUser(entry.Module) {
			continue
		}
		for _, instance := range entry.Instances {
			if instance.Deposed != "" {
				continue
			}
			var key string
			if json.Unmarshal(instance.Key, &key) != nil || key == "" {
				return nil, errors.New("unexpected user key in AD Terraform state")
			}
			tracked[key] = true
		}
	}
	return tracked, nil
}

func newPasswordKeys(inventory map[string]*user, tracked map[string]bool, passwords map[string]string) []string {
	keys := make([]string, 0)
	for key, entry := range inventory {
		if !tracked[key] && passwords[key] == "" && entry.needsPassword() {
			keys = append(keys, key)
		}
	}
	slices.Sort(keys)
	return keys
}

func validateKeys(keys []string) error {
	seen := make(map[string]bool, len(keys))
	for _, key := range keys {
		if !keyPattern.MatchString(key) {
			return errors.New("automatic password keys must start with a lowercase ASCII letter or digit and contain only lowercase letters, digits, underscores or hyphens")
		}
		if seen[key] {
			return errors.New("duplicate user keys in password manifest")
		}
		seen[key] = true
	}
	return nil
}

func verifyPlan(output []byte, inventory map[string]*user, passwords map[string]string) error {
	var plan struct {
		Changes []struct {
			resource
			Module string          `json:"module_address"`
			Index  json.RawMessage `json:"index"`
			Change struct {
				Actions []string `json:"actions"`
			} `json:"change"`
		} `json:"resource_changes"`
	}
	if json.Unmarshal(output, &plan) != nil {
		return errors.New("unexpected AD Terraform plan")
	}
	for _, entry := range plan.Changes {
		if !entry.isDirectoryUser(entry.Module) || !slices.Contains(entry.Change.Actions, "create") {
			continue
		}
		var key string
		if json.Unmarshal(entry.Index, &key) != nil || inventory[key] == nil {
			return errors.New("planned AD user is missing from users.yaml")
		}
		if inventory[key].needsPassword() && passwords[key] == "" {
			return fmt.Errorf("%q requires an initial password. Check AD drift and rerun the plan", key)
		}
	}
	return nil
}

func terraformEnv() []string {
	env := slices.DeleteFunc(os.Environ(), func(entry string) bool {
		name, _, _ := strings.Cut(entry, "=")
		return name == jwtVar || name == passwordVar || name == "TF_LOG" || strings.HasPrefix(name, "TF_LOG_")
	})
	return append(env, "TF_LOG=OFF")
}

func run(mode string) error {
	if strings.EqualFold(os.Getenv("CI_DEBUG_TRACE"), "true") {
		return errors.New("turn off CI_DEBUG_TRACE before running with passwords")
	}
	project, environment := os.Getenv("CI_PROJECT_ID"), os.Getenv("TF_VAR_ad_inventory_environment")
	if !projectPattern.MatchString(project) || !environmentPattern.MatchString(environment) {
		return errors.New("invalid GitLab project ID or AD environment")
	}
	record := manifest{Prefix: "projects/" + project + "/" + environment}
	role := "ad-bootstrap-" + project + "-" + environment

	passwords := make(map[string]string)
	if raw := os.Getenv(passwordVar); raw != "" {
		if json.Unmarshal([]byte(raw), &passwords) != nil || passwords == nil {
			return fmt.Errorf("%s must be a JSON map of nonempty strings", passwordVar)
		}
		for _, password := range passwords {
			if password == "" {
				return fmt.Errorf("%s must be a JSON map of nonempty strings", passwordVar)
			}
		}
	}

	env := terraformEnv()
	var inventory map[string]*user
	if mode == "plan" {
		for _, name := range []string{planFile, manifestFile} {
			if err := os.Remove(name); err != nil && !errors.Is(err, os.ErrNotExist) {
				return fmt.Errorf("cannot remove old %s", name)
			}
		}
		var err error
		inventory, err = readInventory(env)
		if err != nil {
			return err
		}
		output, err := terraformOutput(env, "", "state", "pull", "-no-color")
		if err != nil {
			return errors.New("cannot read the AD Terraform state. Check access to the GitLab backend")
		}
		tracked, err := trackedUsers(output)
		if err != nil {
			return err
		}
		record.Users = newPasswordKeys(inventory, tracked, passwords)
	} else {
		output, err := os.ReadFile(manifestFile)
		var saved manifest
		if err != nil || json.Unmarshal(output, &saved) != nil || saved.Users == nil {
			return errors.New("missing or invalid password manifest. Run a fresh pipeline before applying")
		}
		if saved.Prefix != record.Prefix {
			return errors.New("password manifest belongs to another project or environment")
		}
		record = saved
	}

	if err := validateKeys(record.Users); err != nil {
		return err
	}
	if len(record.Users) > 0 {
		vault, err := loginVault(role + "-" + mode)
		if err != nil {
			return err
		}
		for _, key := range record.Users {
			password, err := vault.initialPassword(record.Prefix, role, key, mode == "plan")
			if err != nil {
				return err
			}
			passwords[key] = password
		}
	}
	fmt.Printf("AD initial passwords loaded from Vault: %d\n", len(record.Users))
	data, err := json.Marshal(passwords)
	if err != nil {
		return err
	}
	env = append(env, passwordVar+"="+string(data))

	if mode == "apply" {
		path, err := exec.LookPath("terraform")
		if err != nil {
			return err
		}
		return syscall.Exec(path, []string{"terraform", "apply", "-lock-timeout=2m", "-no-color", planFile}, env)
	}
	cmd := exec.Command("terraform", "plan", "-lock-timeout=2m", "-no-color", "-out="+planFile)
	cmd.Env, cmd.Stdout, cmd.Stderr = env, os.Stdout, os.Stderr
	if err := cmd.Run(); err != nil {
		return err
	}
	output, err := terraformOutput(terraformEnv(), "", "show", "-json", planFile)
	if err != nil {
		return errors.New("cannot inspect the saved AD Terraform plan")
	}
	if err := verifyPlan(output, inventory, passwords); err != nil {
		return err
	}
	data, err = json.Marshal(record)
	if err != nil {
		return err
	}
	return os.WriteFile(manifestFile, append(data, '\n'), 0600)
}

func main() {
	if len(os.Args) != 2 || (os.Args[1] != "plan" && os.Args[1] != "apply") {
		fmt.Fprintln(os.Stderr, "Usage: ad-password-bootstrap plan|apply")
		os.Exit(2)
	}
	if err := run(os.Args[1]); err != nil {
		fmt.Fprintf(os.Stderr, "AD password bootstrap: %v\n", err)
		os.Exit(1)
	}
}
