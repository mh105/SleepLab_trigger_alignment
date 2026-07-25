# -*- mode: python ; coding: utf-8 -*-

import sys
import tomllib
from pathlib import Path


project_dir = Path(SPECPATH).resolve()
app_name = "EDF Deidentifier"
with (project_dir / "pyproject.toml").open("rb") as metadata_file:
    app_version = tomllib.load(metadata_file)["project"]["version"]

analysis = Analysis(
    [str(project_dir / "packaging" / "entrypoint.py")],
    pathex=[str(project_dir / "src")],
    binaries=[],
    datas=[(str(project_dir / "THIRD_PARTY_NOTICES.md"), ".")],
    hiddenimports=[],
    hookspath=[],
    hooksconfig={},
    runtime_hooks=[],
    excludes=[],
    noarchive=False,
    optimize=0,
)
pyz = PYZ(analysis.pure)

executable = EXE(
    pyz,
    analysis.scripts,
    [],
    exclude_binaries=True,
    name=app_name,
    debug=False,
    bootloader_ignore_signals=False,
    strip=False,
    upx=False,
    console=False,
    disable_windowed_traceback=False,
    argv_emulation=False,
    target_arch=None,
    codesign_identity=None,
    entitlements_file=None,
)

collected = COLLECT(
    executable,
    analysis.binaries,
    analysis.datas,
    strip=False,
    upx=False,
    name=app_name,
)

if sys.platform == "darwin":
    app = BUNDLE(
        collected,
        name=f"{app_name}.app",
        bundle_identifier="org.sleeplab.edfdeidentifier",
        info_plist={
            "CFBundleDisplayName": app_name,
            "CFBundleName": app_name,
            "CFBundleShortVersionString": app_version,
            "CFBundleVersion": "1",
            "NSHighResolutionCapable": True,
        },
    )
