#!/usr/bin/env python3
"""Configure stable Android release signing only when all GitHub secrets exist.

Never check a keystore or password into the public repository. Without these
secrets CI can still make a debug-key-signed *preview*, not an updateable release.
"""
import base64
import os
from pathlib import Path

keys = (
    "RAHA_KEYSTORE_B64",
    "RAHA_STORE_PASSWORD",
    "RAHA_KEY_ALIAS",
    "RAHA_KEY_PASSWORD",
)
supplied = [bool(os.getenv(x)) for x in keys]
gradle = Path("android/app/build.gradle.kts")
if not gradle.exists():
    raise RuntimeError("Expected Flutter-generated android/app/build.gradle.kts")

if not any(supplied):
    print("::warning::No stable Android signing key configured. "
          "Preview APKs from different CI runs cannot update one another.")
    Path("APP_SIGNING.txt").write_text(
        "PREVIEW: Signed by an ephemeral CI debug key.\n"
        "Direct in-place Android updates from earlier APKs are NOT guaranteed.\n"
        "Configure stable GitHub Actions signing secrets before distributing releases.\n"
        "Package ID must remain org.tehrantransit.tehran_transit.\n",
        encoding="utf-8",
    )
    raise SystemExit(0)

if not all(supplied):
    raise RuntimeError(
        "Some Android signing secrets are missing. "
        "Provide all four RAHA_* values or none."
    )

data = base64.b64decode(os.environ["RAHA_KEYSTORE_B64"], validate=True)
if len(data) < 2000 or len(data) > 3 * 1024 * 1024:
    raise RuntimeError("Unexpected Android keystore size")
keystore = Path("android/app/raha-release.jks")
keystore.write_bytes(data)
keystore.chmod(0o600)

text = gradle.read_text(encoding="utf-8")
original = 'signingConfig = signingConfigs.getByName("debug")'
if original not in text:
    raise RuntimeError("Flutter-generated release signing block changed")
block = '''
    signingConfigs {
        create("rahaRelease") {
            storeFile = file("raha-release.jks")
            storePassword = System.getenv("RAHA_STORE_PASSWORD")
            keyAlias = System.getenv("RAHA_KEY_ALIAS")
            keyPassword = System.getenv("RAHA_KEY_PASSWORD")
        }
    }
'''
if "    buildTypes {" not in text:
    raise RuntimeError("Cannot locate Android Gradle buildTypes")
text = text.replace("    buildTypes {", block + "    buildTypes {", 1)
text = text.replace(
    original, 'signingConfig = signingConfigs.getByName("rahaRelease")', 1
)
gradle.write_text(text, encoding="utf-8")
Path("APP_SIGNING.txt").write_text(
    "RELEASE: Signed with the stable user-provided Android release keystore.\n"
    "For in-place upgrades preserve the same package ID, private key and "
    "monotonically increasing versionCode.\n"
    "Old debug-signed APKs with other certificates remain incompatible.\n",
    encoding="utf-8",
)
print("Android release signing configured using encrypted runner secrets.")
