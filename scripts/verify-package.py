#!/usr/bin/env python3
"""Validate the actual packaged version, permissions and icon references before delivery."""
import json
from pathlib import Path
import re
import shutil
import zipfile

root = Path(__file__).resolve().parent.parent
hap = root / 'entry/build/default/outputs/default/entry-default-unsigned.hap'
with zipfile.ZipFile(hap) as archive:
    metadata = json.loads(archive.read('module.json'))
    version = metadata['app']['versionName']
    source = (root / 'entry/src/main/ets/model/Models.ets').read_text()
    assert re.search(r"APP_VERSION: string = '([^']+)'", source)[1] == version, 'UI / package version mismatch'
    assert '4' not in version, 'Version must not include digit 4'
    assert metadata['app']['bundleName'] == 'com.hohode.localchat'
    assert metadata['app']['icon'] == '$media:layered_image'
    ability = metadata['module']['abilities'][0]
    assert ability['icon'] == '$media:layered_image'
    assert ability['startWindowIcon'] == '$media:app_icon'
    layers = json.loads(archive.read('resources/base/media/layered_image.json'))['layered-image']
    assert set(layers) == {'background', 'foreground'}
    assert layers['background'] != layers['foreground']
    assert all(re.fullmatch(r'\$media:\d+', ref) for ref in layers.values())
    for media in ['AppScope/resources/base/media', 'entry/src/main/resources/base/media']:
        source_layers = json.loads((root / media / 'layered_image.json').read_text())['layered-image']
        assert source_layers == {'background': '$media:background', 'foreground': '$media:foreground'}
        for name in ['foreground.png', 'background.png', 'app_icon.png']:
            assert (root / media / name).read_bytes() == (root / 'distribution' / name).read_bytes()
    for name in ['foreground.png', 'background.png']:
        assert 'resources/base/media/' + name in archive.namelist()
    assert 'resources/base/media/app_icon.png' in archive.namelist()
    assert any(p['name'] == 'ohos.permission.STORE_PERSISTENT_DATA' for p in metadata['module']['requestPermissions'])
    assert any(p['name'] == 'ohos.permission.INTERNET' for p in metadata['module']['requestPermissions'])
output = root / f'distribution/邻聊-HarmonyOS-v{version}-unsigned.hap'
shutil.copyfile(hap, output)
print(f'PASS package: v{version}, app/launcher/startup icon, internet permission')
print(f'Unsigned HAP: {output}')

signed = hap.with_name('entry-default-signed.hap')
if signed.exists():
    with zipfile.ZipFile(signed) as archive:
        signed_metadata = json.loads(archive.read('module.json'))
    if signed_metadata['app']['versionName'] == version:
        signed_output = root / f'distribution/邻聊-HarmonyOS-v{version}-signed.hap'
        shutil.copyfile(signed, signed_output)
        print(f'Signed HAP: {signed_output}')
