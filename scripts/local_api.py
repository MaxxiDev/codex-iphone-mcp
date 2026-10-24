#!/usr/bin/env python3
"""Authenticated loopback requests for the reviewed build. Never print the token."""
import argparse
import os
from pathlib import Path
import re
import stat
import sys
import urllib.request
from urllib.parse import urlsplit


def read_token():
    path = Path(os.environ.get('IPHONE_USE_AUTH_FILE',
                    str(Path.home() / 'Library/Application Support/iPhoneUse/api-token')))
    if not path.is_absolute():
        raise ValueError('IPHONE_USE_AUTH_FILE must be absolute')
    fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
    with os.fdopen(fd, 'rb') as handle:
        info = os.fstat(handle.fileno())
        if (not stat.S_ISREG(info.st_mode) or info.st_uid != os.getuid()
                or stat.S_IMODE(info.st_mode) != 0o600 or info.st_size != 65):
            raise ValueError('API token must be an owner-only (0600) regular file')
        data = handle.read(66)
    if not re.fullmatch(rb'[0-9a-f]{64}\n', data):
        raise ValueError('Invalid API token file')
    return data[:-1].decode('ascii')


def authenticated_request(url, data=None):
    parts = urlsplit(url)
    if (parts.scheme != 'http' or parts.hostname not in ('127.0.0.1', 'localhost')
            or not parts.port or parts.username or parts.password):
        raise ValueError('Only local iPhone Use HTTP URLs are allowed')
    return urllib.request.Request(url, data=data, headers={
        'Authorization': 'Bearer ' + read_token(), 'Content-Type': 'application/json',
    })


class NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, *args, **kwargs):
        raise ValueError('Refusing to forward local API credentials through a redirect')


def open_request(request, timeout=5):
    return urllib.request.build_opener(urllib.request.ProxyHandler({}), NoRedirect()).open(request, timeout=timeout)


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('url')
    parser.add_argument('-o', '--output')
    args = parser.parse_args()
    try:
        with open_request(authenticated_request(args.url)) as response:
            data = response.read()
        if args.output:
            Path(args.output).write_bytes(data)
        else:
            sys.stdout.buffer.write(data)
    except Exception as error:
        print(f'Local API request failed: {error}', file=sys.stderr)
        sys.exit(1)
