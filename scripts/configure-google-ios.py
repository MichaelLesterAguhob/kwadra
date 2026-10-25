"""Configure non-secret Google iOS OAuth IDs without Firebase Authentication."""
import argparse
import plistlib
import re
from pathlib import Path

parser = argparse.ArgumentParser()
parser.add_argument("--client-id", required=True)
parser.add_argument("--server-client-id", required=True)
args = parser.parse_args()
for value in (args.client_id, args.server_client_id):
    if not re.fullmatch(r"[a-zA-Z0-9-]+\.apps\.googleusercontent\.com", value):
        parser.error("Use the OAuth client IDs from Google Cloud.")
target = Path(__file__).resolve().parents[1] / "apps/management/ios/Runner/Info.plist"
with target.open("rb") as handle:
    data = plistlib.load(handle)
data["GIDClientID"] = args.client_id
data["GIDServerClientID"] = args.server_client_id
types = [t for t in data.get("CFBundleURLTypes", []) if t.get("CFBundleURLName") != "google"]
types.append({"CFBundleURLName": "google", "CFBundleURLSchemes": [".".join(reversed(args.client_id.split(".")))]})
data["CFBundleURLTypes"] = types
with target.open("wb") as handle:
    plistlib.dump(data, handle, sort_keys=False)
print("Configured Google iOS URL scheme. Rebuild the app on macOS for device testing.")
