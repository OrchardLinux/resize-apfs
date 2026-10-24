#!/usr/bin/env python3
"""Select release outputs without building or calling GitHub."""
import os
import re


def plan(event, version, private, ref, run_id):
    if not re.fullmatch(r'[A-Za-z0-9][A-Za-z0-9._-]*', version):
        raise ValueError('Invalid release version.')
    if private not in {'true', 'false'}:
        raise ValueError('Repository visibility must be specified.')
    tag = ''
    kind = 'none'
    if event == 'push' and ref == 'refs/tags/' + version and version.startswith('v'):
        tag = version
        kind = 'private-preview' if private == 'true' else 'release'
    elif event == 'workflow_dispatch':
        if private == 'true':
            if not run_id.isdigit():
                raise ValueError('Missing workflow run ID.')
            tag = f'private-{version}-{run_id}'
            kind = 'private-preview'
    else:
        raise ValueError('Only manual runs and version tags may build releases.')
    return {'version': version, 'release_tag': tag, 'release_kind': kind,
            'attest': 'true' if private == 'false' else 'false'}


if __name__ == '__main__':
    try:
        result = plan(os.environ.get('GITHUB_EVENT_NAME', ''), os.environ.get('VERSION', ''),
                      os.environ.get('REPOSITORY_PRIVATE', ''), os.environ.get('GITHUB_REF', ''),
                      os.environ.get('GITHUB_RUN_ID', ''))
    except ValueError as error:
        raise SystemExit(str(error))
    output = ''.join(f'{key}={value}\n' for key, value in result.items())
    if os.environ.get('GITHUB_OUTPUT'):
        with open(os.environ['GITHUB_OUTPUT'], 'a') as stream:
            stream.write(output)
    print(output, end='')
