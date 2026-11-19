#!/usr/bin/env python3
"""Read-only checks for third-party WeChat mobile sign-in evidence.

No networking, credentials, account IDs, SMS messages, live client imports,
or executable third-party binary loading. Checks are fail-closed.
"""
import argparse
import json
from pathlib import Path


def inspect(root: Path, current: Path):
    refs = {
        "go_manual_password": root / "models/Login/Data62.go",
        "go_sms_controller": root / "controllers/Login.go",
        "go_crypto_loader": root / "clientsdk/v08/v08.go",
        "go_crypto_wrapper": root / "Algorithm/CCD.go",
        "ios_transport": current / "client.rs",
        "ios_ffi": current / "lib.rs",
    }
    source = {}
    for name, path in refs.items():
        if not path.is_file():
            raise FileNotFoundError(f"Missing evidence source: {name}: {path}")
        source[name] = path.read_text(encoding="utf-8", errors="replace")

    checks = {
        "go_password_manual_auth_request": 'ManualAuthRsaReqData{' in source["go_manual_password"]
            and "secmanualauth" in source["go_manual_password"],
        "go_password_depends_on_ccdata": "GetWcstf08" in source["go_manual_password"]
            and "GetWcste08" in source["go_manual_password"],
        "go_password_hash_source": "MD5ToLower(Data.Password)" in source["go_manual_password"],
        "go_sms_is_secondary_to_password": "WXDATA := Login.Data62(reqdata," in source["go_sms_controller"]
            and 'strings.Index(message.GetBaseResponse().GetErrMsg().GetString_(), "&ticket=")' in source["go_sms_controller"],
        "go_sms_apply_verify_defined": all(f"func (c *LoginController) {n}()" in source["go_sms_controller"]
            for n in ("Data62SMSApply", "Data62SMSVerify", "Data62SMSAgain")),
        "go_v08_requires_external_dll_or_so": 'libPath = "lib\\\\v08.dll"' in source["go_crypto_loader"]
            or '"libv08.so"' in source["go_crypto_loader"],
        "go_v08_unsupported_on_darwin": 'panic("unsupported platform")' in source["go_crypto_loader"],
        "go_crypto_depends_on_v08": "v08.Compress" in source["go_crypto_wrapper"],
        "ios_qr_secmanualauth_present": '"/cgi-bin/micromsg-bin/secmanualauth"' in source["ios_transport"],
        "ios_existing_pc_identity": '"UnifiedPCLinux x86_64"' in source["ios_ffi"],
        "ios_password_sms_auth_verified": False,  # no server-verified mobile proof; never infer it
    }
    assert all(checks[k] for k in checks if k != "ios_password_sms_auth_verified"), checks
    return {
        "assessment": "offline_research_only",
        "server_login_performed": False,
        "password_sms_feature_enabled": False,
        "checks": checks,
        "findings": [
            "A third-party Go source contains a manual-auth protobuf shape and a password hash.",
            "SMS appears in the source as a SECOND FACTOR after manual password authentication.",
            "The v08 device-security component depends on a nonportable external library.",
            "The existing iOS engine uses approved QR/manual-auth and a desktop PC identity.",
            "No verified, complete, first-party-compatible mobile password/SMS flow is available."
        ],
        "next_validation_requirements": [
            "Independent reproducible iOS-compatible device-security generation",
            "Offline golden tests for request and response encoding",
            "Explicit challenge-state and error-handling tests",
            "Confirmed mobile credential-to-session derivation",
            "Only then an opt-in test on device with secrets held locally"
        ]
    }


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("--reference-root", type=Path, required=True)
    parser.add_argument("--protocol-src", type=Path, required=True)
    args = parser.parse_args()
    print(json.dumps(inspect(args.reference_root, args.protocol_src),
                     indent=2, ensure_ascii=False))
