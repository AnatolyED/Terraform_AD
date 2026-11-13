#!/usr/bin/env python3
"""Pass Vault-backed initial AD passwords to Terraform without writing them to disk."""

import base64
import json
import os
from pathlib import Path
import re
import ssl
import subprocess
import sys
from urllib.error import HTTPError, URLError
from urllib.parse import urlsplit
from urllib.request import HTTPSHandler, HTTPRedirectHandler, ProxyHandler, Request, build_opener


class BootstrapError(Exception):
    pass


class NoRedirect(HTTPRedirectHandler):
    def redirect_request(self, *args, **kwargs):
        return None


class Vault:
    def __init__(self, mode, role_prefix):
        self.address = os.environ["AD_BOOTSTRAP_VAULT_ADDR"].rstrip("/")
        url = urlsplit(self.address)
        if url.scheme != "https" or not url.hostname or url.username or url.password or url.path or url.query or url.fragment:
            raise BootstrapError("AD_BOOTSTRAP_VAULT_ADDR must be a Vault HTTPS origin.")
        context = ssl.create_default_context(cafile=os.environ["AD_BOOTSTRAP_VAULT_CACERT"])
        self.opener = build_opener(ProxyHandler({}), NoRedirect(), HTTPSHandler(context=context))
        self.token = None
        self.namespace = os.environ.get("AD_BOOTSTRAP_VAULT_NAMESPACE", "")
        status, result = self.request(
            "authenticate",
            "auth/gitlab-jwt/login",
            {"role": f"{role_prefix}-{mode}", "jwt": os.environ["AD_BOOTSTRAP_VAULT_JWT"]},
        )
        if status != 200:
            raise BootstrapError(f"Vault JWT login failed (HTTP {status}).")
        self.token = result["auth"]["client_token"]

    def request(self, operation, path, payload=None):
        headers = {"Content-Type": "application/json"}
        if self.namespace:
            headers["X-Vault-Namespace"] = self.namespace
        if self.token:
            headers["X-Vault-Token"] = self.token
        body = json.dumps(payload).encode() if payload is not None else None
        request = Request(f"{self.address}/v1/{path}", data=body, headers=headers)
        try:
            with self.opener.open(request, timeout=15) as response:
                return response.status, json.load(response)
        except HTTPError as error:
            with error:
                return error.code, {}
        except (URLError, TimeoutError):
            raise BootstrapError(f"Vault {operation} failed. Check runner connectivity and TLS.") from None


def terraform_output(arguments, error_message, expression=None):
    result = subprocess.run(
        ["terraform", *arguments], input=expression, text=True, capture_output=True, check=False,
    )
    if result.returncode != 0:
        raise BootstrapError(error_message)
    return result.stdout


def read_inventory():
    # Use Terraform's own YAML parser and inventory path, from the AD root.
    output = terraform_output(
        ["console", "-no-color"],
        "Cannot read the AD inventory through terraform console. Check YAML and backend.",
        'base64encode(jsonencode(yamldecode(file("${local.inventory_directory}/users.yaml"))))\n',
    )
    inventory = json.loads(base64.b64decode(json.loads(output), validate=True))
    if not isinstance(inventory, dict) or any(not isinstance(user, dict) for user in inventory.values()):
        raise BootstrapError("Expected a map of AD users in users.yaml.")
    return inventory


def tracked_users():
    output = terraform_output(
        ["state", "pull", "-no-color"],
        "Cannot read the AD Terraform state. Check access to the GitLab backend.",
    )
    if not output.strip():
        return set()
    resources = json.loads(output)["resources"]
    return {
        instance["index_key"]
        for resource in resources
        if is_directory_user(resource, "module")
        for instance in resource["instances"]
        if "deposed" not in instance
    }


def is_directory_user(resource, module_key):
    return (
        resource.get(module_key) == "module.directory"
        and resource["mode"] == "managed"
        and resource["type"] == "ad_user"
        and resource["name"] == "directory"
    )


def needs_password(user):
    return user.get("enabled") is True or user.get("change_password_at_logon") is False


def new_password_keys(inventory, legacy):
    tracked = tracked_users()
    return sorted(key for key, user in inventory.items()
                  if key not in tracked and key not in legacy and needs_password(user))


def verify_plan(inventory, passwords):
    output = terraform_output(
        ["show", "-json", "deployment.tfplan"],
        "Cannot inspect the saved AD Terraform plan.",
    )
    for resource in (json.loads(output).get("resource_changes") or []):
        if is_directory_user(resource, "module_address") and "create" in resource["change"]["actions"]:
            key = resource["index"]
            if needs_password(inventory[key]) and key not in passwords:
                raise BootstrapError(f"{key} requires an initial password. Check AD drift and rerun the plan.")


def checked_keys(keys):
    if not isinstance(keys, list) or any(
        not isinstance(key, str) or not re.fullmatch(r"[a-z0-9][a-z0-9_-]*", key)
        for key in keys
    ):
        raise BootstrapError("Automatic password keys must contain lowercase ASCII letters, digits, underscores or hyphens.")
    if len(set(keys)) != len(keys):
        raise BootstrapError("Duplicate user keys in password manifest.")
    return keys


def passwords_for(vault, prefix, keys, create):
    password_policy = "ad-bootstrap-" + prefix.removeprefix("projects/").replace("/", "-")
    passwords = {}
    for key in checked_keys(keys):
        path = f"ad-bootstrap/data/{prefix}/{key}"
        status, result = vault.request("read password", f"{path}?version=1")
        if status == 404 and create:
            generated_status, generated = vault.request("generate password", f"sys/policies/password/{password_policy}/generate")
            if generated_status != 200:
                raise BootstrapError(f"Vault password generation failed (HTTP {generated_status}).")
            password = generated["data"]["password"]
            if not isinstance(password, str) or not password:
                raise BootstrapError("Vault returned an empty or invalid generated password.")
            written, _ = vault.request("create password", path, {"options": {"cas": 0}, "data": {"password": password}})
            if written not in (200, 204, 400, 403):
                raise BootstrapError(f"Vault could not create the password for {key} (HTTP {written}).")
            status, result = vault.request("read password", f"{path}?version=1")
        if status != 200:
            raise BootstrapError(f"Vault password for {key} is unavailable (HTTP {status}).")
        password = result["data"]["data"]["password"]
        if not isinstance(password, str) or not password or result["data"]["metadata"]["version"] != 1:
            raise BootstrapError(f"Vault returned an invalid initial password for {key}.")
        passwords[key] = password
    return passwords


def main():
    mode, = sys.argv[1:]
    if mode not in ("plan", "apply"):
        raise BootstrapError("Expected plan or apply.")
    if os.environ.get("CI_DEBUG_TRACE", "").lower() == "true":
        raise BootstrapError("Turn off CI_DEBUG_TRACE before running with passwords.")
    os.environ["TF_LOG"] = "OFF"
    for name in ("TF_LOG_CORE", "TF_LOG_PROVIDER", "TF_LOG_PATH", "TF_LOG_SDK", "TF_LOG_SDK_FRAMEWORK", "TF_LOG_SDK_PROTO"):
        os.environ.pop(name, None)

    project = os.environ["CI_PROJECT_ID"]
    environment = os.environ["TF_VAR_ad_inventory_environment"]
    if not re.fullmatch(r"[1-9][0-9]*", project) or not re.fullmatch(r"[a-z][a-z0-9-]*", environment):
        raise BootstrapError("Invalid GitLab project ID or AD environment.")
    prefix = f"projects/{project}/{environment}"
    role_prefix = f"ad-bootstrap-{project}-{environment}"
    legacy = json.loads(os.environ.get("TF_VAR_ad_user_passwords") or "{}")
    if not isinstance(legacy, dict) or any(not isinstance(value, str) or not value for value in legacy.values()):
        raise BootstrapError("TF_VAR_ad_user_passwords must be a JSON map of nonempty strings.")

    manifest = Path("ad-bootstrap-users.json")
    if mode == "plan":
        manifest.unlink(missing_ok=True)
        Path("deployment.tfplan").unlink(missing_ok=True)
        inventory = read_inventory()
        keys = checked_keys(new_password_keys(inventory, legacy))
    else:
        if not manifest.is_file():
            raise BootstrapError("Missing password manifest. Run a fresh pipeline before applying.")
        record = json.loads(manifest.read_text())
        if record["prefix"] != prefix:
            raise BootstrapError("Password manifest belongs to another project or environment.")
        keys = checked_keys(record["users"])

    generated = passwords_for(Vault(mode, role_prefix), prefix, keys, create=(mode == "plan")) if keys else {}
    passwords = {**legacy, **generated}
    print(f"AD initial passwords loaded from Vault: {len(generated)}", flush=True)
    os.environ["TF_VAR_ad_user_passwords"] = json.dumps(passwords)
    os.environ.pop("AD_BOOTSTRAP_VAULT_JWT", None)
    if mode == "apply":
        os.execvp("terraform", ["terraform", "apply", "-lock-timeout=2m", "-no-color", "deployment.tfplan"])

    plan = ["terraform", "plan", "-lock-timeout=2m", "-no-color", "-out=deployment.tfplan"]
    result = subprocess.run(plan, check=False)
    if result.returncode:
        return result.returncode
    verify_plan(inventory, passwords)
    manifest.write_text(json.dumps({"prefix": prefix, "users": keys}) + "\n")
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except BootstrapError as error:
        print(f"AD password bootstrap: {error}", file=sys.stderr)
        sys.exit(1)
    except KeyError as error:
        variable = error.args[0]
        if isinstance(variable, str) and variable.startswith(("AD_BOOTSTRAP_", "TF_VAR_", "CI_")):
            print(f"AD password bootstrap: missing GitLab variable {variable}.", file=sys.stderr)
        else:
            print("AD password bootstrap: unexpected state, plan, or Vault response.", file=sys.stderr)
        sys.exit(1)
    except (OSError, ValueError, TypeError, IndexError):
        print("AD password bootstrap: invalid input, TLS configuration, or Vault response.", file=sys.stderr)
        sys.exit(1)
