#!/usr/bin/env python3
"""Download an HLS m3u8 URL to an MP4 file, using ffmpeg only to combine."""

from __future__ import annotations

import argparse
import os
import re
import shlex
import shutil
import socket
import subprocess
import sys
import tempfile
from dataclasses import dataclass
from concurrent.futures import ThreadPoolExecutor, as_completed
from urllib.parse import unquote, urljoin, urlparse
from urllib.error import URLError
from urllib.request import Request, urlopen


DEFAULT_TIMEOUT = 30
DEFAULT_RETRIES = 3
DEFAULT_SEGMENT_WORKERS = 8
PROJECT_DIR = os.path.dirname(os.path.abspath(__file__))
DEFAULT_DOWNLOAD_DIR = os.path.expanduser("~/Downloads")
QUALITY_HEIGHTS = {
    "720p": 720,
    "1080p": 1080,
}


@dataclass(frozen=True)
class CurlRequest:
    url: str
    headers: list[str]


def validate_url(url: str) -> str:
    parsed = urlparse(url)
    if parsed.scheme not in {"http", "https"}:
        raise ValueError("URL must start with http:// or https://")
    if not parsed.netloc:
        raise ValueError("URL must include a host")
    return url


def is_remote_source(source: str) -> bool:
    return urlparse(source).scheme in {"http", "https"}


def validate_source(source: str) -> str:
    if is_remote_source(source):
        return validate_url(source)

    parsed = urlparse(source)
    if parsed.scheme:
        raise ValueError("Source must be an HTTP(S) URL or a local .m3u8 file path")
    if not source.lower().endswith(".m3u8"):
        raise ValueError("Local source must be an .m3u8 file")
    if not os.path.isfile(source):
        raise ValueError("Local m3u8 file was not found")
    return source


def normalize_output_path(output_path: str) -> str:
    root, extension = os.path.splitext(output_path)
    if extension.lower() == ".mp4":
        return output_path
    if not root and extension:
        return f"{output_path}.mp4"
    return f"{output_path}.mp4"


def default_output_filename(source: str) -> str:
    if is_remote_source(source):
        parsed = urlparse(source)
        filename = os.path.basename(unquote(parsed.path))
    else:
        filename = os.path.basename(source)
    stem, extension = os.path.splitext(filename)

    if stem and extension.lower() == ".m3u8":
        return normalize_output_path(stem)
    if stem:
        return normalize_output_path(stem)
    return "download.mp4"


def default_output_path(source: str) -> str:
    return os.path.join(DEFAULT_DOWNLOAD_DIR, default_output_filename(source))


def format_headers(headers: list[str] | None) -> str | None:
    if not headers:
        return None
    return "".join(f"{header}\r\n" for header in headers)


def headers_to_dict(headers: list[str] | None) -> dict[str, str]:
    header_dict = {}
    for header in headers or []:
        name, separator, value = header.partition(":")
        if separator:
            header_dict[name.strip()] = value.strip()
    return header_dict


def parse_curl_request(curl_request: str) -> CurlRequest:
    normalized = re.sub(r"\\\r?\n", " ", curl_request.strip())
    normalized = re.sub(r"\$'([^']*)'", r"'\1'", normalized)
    try:
        tokens = shlex.split(normalized)
    except ValueError as error:
        raise ValueError(f"Could not parse cURL request: {error}") from error

    if not tokens or os.path.basename(tokens[0]).lower() not in {"curl", "curl.exe"}:
        raise ValueError("cURL request must start with curl")

    urls: list[str] = []
    headers: list[str] = []
    cookie_values: list[str] = []
    user_agent: str | None = None
    referer: str | None = None
    options_with_values = {
        "--abstract-unix-socket",
        "--aws-sigv4",
        "--cacert",
        "--capath",
        "--cert",
        "--cert-status",
        "--cert-type",
        "--ciphers",
        "--connect-timeout",
        "--connect-to",
        "--continue-at",
        "--data",
        "--data-ascii",
        "--data-binary",
        "--data-raw",
        "--data-urlencode",
        "--dns-interface",
        "--dns-ipv4-addr",
        "--dns-ipv6-addr",
        "--dns-servers",
        "--doh-url",
        "--dump-header",
        "--egd-file",
        "--engine",
        "--form",
        "--form-string",
        "--ftp-account",
        "--ftp-alternative-to-user",
        "--hostpubmd5",
        "--hostpubsha256",
        "--interface",
        "--key",
        "--key-type",
        "--krb",
        "--limit-rate",
        "--local-port",
        "--login-options",
        "--mail-auth",
        "--mail-from",
        "--mail-rcpt",
        "--max-filesize",
        "--max-redirs",
        "--netrc-file",
        "--oauth2-bearer",
        "--output",
        "--pass",
        "--pinnedpubkey",
        "--proto",
        "--proto-default",
        "--proto-redir",
        "--proxy",
        "--proxy-cacert",
        "--proxy-capath",
        "--proxy-cert",
        "--proxy-cert-type",
        "--proxy-ciphers",
        "--proxy-header",
        "--proxy-key",
        "--proxy-key-type",
        "--proxy-pass",
        "--proxy-service-name",
        "--proxy-tls13-ciphers",
        "--proxy-tlsauthtype",
        "--proxy-tlspassword",
        "--proxy-tlsuser",
        "--proxy-user",
        "--pubkey",
        "--quote",
        "--range",
        "--request",
        "--request-target",
        "--resolve",
        "--retry",
        "--retry-connrefused",
        "--retry-delay",
        "--retry-max-time",
        "--service-name",
        "--socks4",
        "--socks4a",
        "--socks5",
        "--socks5-basic",
        "--socks5-gssapi",
        "--socks5-gssapi-nec",
        "--socks5-gssapi-service",
        "--socks5-hostname",
        "--speed-limit",
        "--speed-time",
        "--stderr",
        "--telnet-option",
        "--tftp-blksize",
        "--tls13-ciphers",
        "--tlspassword",
        "--tlsuser",
        "--unix-socket",
        "--upload-file",
        "--user",
    }
    short_options_with_values = {
        "-A",
        "-b",
        "-c",
        "-d",
        "-e",
        "-F",
        "-H",
        "-K",
        "-m",
        "-o",
        "-Q",
        "-r",
        "-T",
        "-u",
        "-x",
        "-X",
        "-Y",
        "-z",
    }

    def option_value(index: int, token: str, long_name: str, short_name: str) -> tuple[str | None, int]:
        if token == long_name or token == short_name:
            if index + 1 >= len(tokens):
                raise ValueError(f"{token} requires a value")
            return tokens[index + 1], index + 2
        long_prefix = f"{long_name}="
        if token.startswith(long_prefix):
            return token[len(long_prefix) :], index + 1
        if short_name and token.startswith(short_name) and token != short_name:
            return token[len(short_name) :], index + 1
        return None, index

    index = 1
    while index < len(tokens):
        token = tokens[index]

        value, next_index = option_value(index, token, "--header", "-H")
        if value is not None:
            if ":" in value:
                headers.append(value.strip())
            index = next_index
            continue

        value, next_index = option_value(index, token, "--cookie", "-b")
        if value is not None:
            stripped = value.strip()
            if "=" in stripped or ";" in stripped:
                cookie_values.append(stripped)
            index = next_index
            continue

        value, next_index = option_value(index, token, "--url", "")
        if value is not None:
            urls.append(value.strip())
            index = next_index
            continue

        value, next_index = option_value(index, token, "--user-agent", "-A")
        if value is not None:
            user_agent = value.strip()
            index = next_index
            continue

        value, next_index = option_value(index, token, "--referer", "-e")
        if value is not None:
            referer = value.strip()
            index = next_index
            continue

        if token.startswith("http://") or token.startswith("https://"):
            urls.append(token)
            index += 1
            continue

        if token.startswith("--") and "=" not in token and token in options_with_values:
            index += 2
            continue
        if token in short_options_with_values:
            index += 2
            continue
        if any(token.startswith(option) and token != option for option in short_options_with_values):
            index += 1
            continue
        index += 1

    if user_agent and not any(header.partition(":")[0].strip().lower() == "user-agent" for header in headers):
        headers.append(f"User-Agent: {user_agent}")
    if referer and not any(header.partition(":")[0].strip().lower() == "referer" for header in headers):
        headers.append(f"Referer: {referer}")
    if cookie_values and not any(header.partition(":")[0].strip().lower() == "cookie" for header in headers):
        headers.append(f"Cookie: {'; '.join(cookie_values)}")

    if not urls:
        raise ValueError("cURL request did not include an HTTP(S) URL")
    selected_url = next((url for url in urls if ".m3u8" in url.lower()), urls[0])
    return CurlRequest(url=validate_url(selected_url), headers=headers)


def is_timeout_error(error: BaseException) -> bool:
    if isinstance(error, (TimeoutError, socket.timeout)):
        return True
    if isinstance(error, URLError):
        return is_timeout_error(error.reason)
    return False


def fetch_url_bytes(
    url: str,
    headers: list[str] | None,
    *,
    timeout: int = DEFAULT_TIMEOUT,
    retries: int = DEFAULT_RETRIES,
) -> bytes:
    request_headers = headers_to_dict(headers)
    request_headers.setdefault(
        "User-Agent",
        "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) "
        "AppleWebKit/537.36 (KHTML, like Gecko) Chrome/136.0.0.0 Safari/537.36",
    )
    request = Request(url, headers=request_headers)
    attempts = max(1, retries)
    for attempt in range(1, attempts + 1):
        try:
            with urlopen(request, timeout=timeout) as response:
                return response.read()
        except Exception as error:
            if attempt == attempts or not is_timeout_error(error):
                raise
            print(
                f"Timed out downloading {url}; retrying ({attempt + 1}/{attempts})...",
                file=sys.stderr,
            )
    raise RuntimeError("unreachable")


def fetch_url_text(
    url: str,
    headers: list[str] | None,
    *,
    timeout: int = DEFAULT_TIMEOUT,
    retries: int = DEFAULT_RETRIES,
) -> str:
    return fetch_url_bytes(url, headers, timeout=timeout, retries=retries).decode("utf-8")


def resolve_playlist_reference(playlist_source: str, uri: str) -> str:
    if is_remote_source(playlist_source) or is_remote_source(uri):
        return urljoin(playlist_source, uri)
    return os.path.abspath(
        os.path.join(os.path.dirname(playlist_source), unquote(uri))
    )


def read_source_bytes(
    source: str,
    headers: list[str] | None,
    *,
    timeout: int = DEFAULT_TIMEOUT,
    retries: int = DEFAULT_RETRIES,
) -> bytes:
    if is_remote_source(source):
        return fetch_url_bytes(source, headers, timeout=timeout, retries=retries)
    with open(source, "rb") as source_file:
        return source_file.read()


def read_source_text(
    source: str,
    headers: list[str] | None,
    *,
    timeout: int = DEFAULT_TIMEOUT,
    retries: int = DEFAULT_RETRIES,
) -> str:
    return read_source_bytes(source, headers, timeout=timeout, retries=retries).decode("utf-8")


def find_ffmpeg() -> str:
    ffmpeg_path = shutil.which("ffmpeg")
    if not ffmpeg_path:
        raise RuntimeError(
            "ffmpeg was not found. Install ffmpeg first, then run this tool again."
        )
    return ffmpeg_path


def build_ffmpeg_command(
    *,
    ffmpeg_path: str,
    url: str,
    output_path: str,
    headers: list[str] | None,
    overwrite: bool,
) -> list[str]:
    command = [ffmpeg_path, "-y" if overwrite else "-n"]
    formatted_headers = format_headers(headers)
    if formatted_headers:
        command.extend(["-headers", formatted_headers])
    command.extend(
        [
            "-allowed_segment_extensions",
            "ALL",
            "-allowed_extensions",
            "ALL",
            "-i",
            url,
            "-c",
            "copy",
            "-bsf:a",
            "aac_adtstoasc",
            output_path,
        ]
    )
    return command


def mpegts_offset(data: bytes) -> int | None:
    max_offset = min(len(data), 4096)
    for offset in range(max_offset):
        if all(
            offset + (188 * packet_index) < len(data)
            and data[offset + (188 * packet_index)] == 0x47
            for packet_index in range(5)
        ):
            return offset
    return None


def strip_segment_prefix(segment_data: bytes) -> bytes:
    offset = mpegts_offset(segment_data)
    if offset is None:
        return segment_data
    return segment_data[offset:]


def playlist_uri_lines(playlist_text: str) -> list[tuple[int, str]]:
    uri_lines = []
    for index, line in enumerate(playlist_text.splitlines()):
        stripped = line.strip()
        if stripped and not stripped.startswith("#"):
            uri_lines.append((index, stripped))
    return uri_lines


def select_variant_playlist_url(
    playlist_text: str,
    playlist_url: str,
    preferred_height: int | None = None,
) -> str | None:
    lines = playlist_text.splitlines()
    variants = []
    for index, line in enumerate(lines):
        if not line.startswith("#EXT-X-STREAM-INF"):
            continue
        bandwidth_match = re.search(r"BANDWIDTH=(\d+)", line)
        bandwidth = int(bandwidth_match.group(1)) if bandwidth_match else 0
        resolution_match = re.search(r"RESOLUTION=\d+x(\d+)", line)
        height = int(resolution_match.group(1)) if resolution_match else None
        for candidate in lines[index + 1 :]:
            stripped = candidate.strip()
            if stripped and not stripped.startswith("#"):
                variants.append((height, bandwidth, urljoin(playlist_url, stripped)))
                break
    if not variants:
        return None
    if preferred_height is not None:
        preferred_variants = [
            variant for variant in variants if variant[0] == preferred_height
        ]
        if preferred_variants:
            return max(preferred_variants, key=lambda variant: variant[1])[2]
    return max(variants, key=lambda variant: variant[1])[2]


def resolve_preferred_playlist_url(
    *,
    url: str,
    headers: list[str] | None,
    preferred_height: int | None,
    timeout: int = DEFAULT_TIMEOUT,
    retries: int = DEFAULT_RETRIES,
) -> str:
    if preferred_height is None:
        return url
    playlist_text = fetch_url_text(url, headers, timeout=timeout, retries=retries)
    return select_variant_playlist_url(playlist_text, url, preferred_height) or url


def rewrite_media_playlist(
    *,
    playlist_text: str,
    playlist_url: str,
    work_dir: str,
    headers: list[str] | None,
    segment_workers: int = DEFAULT_SEGMENT_WORKERS,
    timeout: int = DEFAULT_TIMEOUT,
    retries: int = DEFAULT_RETRIES,
) -> str:
    lines = playlist_text.splitlines()
    segments = list(enumerate(playlist_uri_lines(playlist_text), start=1))
    total_segments = len(segments)

    def download_segment(segment_number: int, line_index: int, segment_uri: str) -> tuple[int, int, str]:
        segment_source = resolve_playlist_reference(playlist_url, segment_uri)
        segment_data = strip_segment_prefix(
            read_source_bytes(segment_source, headers, timeout=timeout, retries=retries)
        )
        segment_filename = f"segment_{segment_number:05d}.ts"
        segment_path = os.path.join(work_dir, segment_filename)
        with open(segment_path, "wb") as segment_file:
            segment_file.write(segment_data)
        return segment_number, line_index, segment_filename

    workers = max(1, min(segment_workers, len(segments))) if segments else 1
    with ThreadPoolExecutor(max_workers=workers) as executor:
        futures = [
            executor.submit(download_segment, segment_number, line_index, segment_uri)
            for segment_number, (line_index, segment_uri) in segments
        ]
        for future in as_completed(futures):
            segment_number, line_index, segment_filename = future.result()
            lines[line_index] = segment_filename
            print(f"Prepared segment {segment_number}/{total_segments}", file=sys.stderr)

    return "\n".join(lines) + "\n"


def prepare_clean_hls_playlist(
    *,
    url: str,
    headers: list[str] | None,
    work_dir: str,
    preferred_height: int | None = None,
    segment_workers: int = DEFAULT_SEGMENT_WORKERS,
    timeout: int = DEFAULT_TIMEOUT,
    retries: int = DEFAULT_RETRIES,
) -> str:
    playlist_url = url
    playlist_text = read_source_text(playlist_url, headers, timeout=timeout, retries=retries)
    variant_url = select_variant_playlist_url(
        playlist_text,
        playlist_url,
        preferred_height,
    )
    if variant_url:
        playlist_url = variant_url
        playlist_text = read_source_text(playlist_url, headers, timeout=timeout, retries=retries)

    rewritten_playlist = rewrite_media_playlist(
        playlist_text=playlist_text,
        playlist_url=playlist_url,
        work_dir=work_dir,
        headers=headers,
        segment_workers=segment_workers,
        timeout=timeout,
        retries=retries,
    )
    playlist_path = os.path.join(work_dir, "cleaned.m3u8")
    with open(playlist_path, "w", encoding="utf-8") as playlist_file:
        playlist_file.write(rewritten_playlist)
    return playlist_path


def parse_args(argv: list[str]) -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Download an HLS .m3u8 URL or local .m3u8 file to an .mp4 file using ffmpeg."
    )
    parser.add_argument("url", help="HTTP(S) m3u8 URL or local .m3u8 file to download")
    parser.add_argument(
        "-o",
        "--output",
        help="Output MP4 file path. Defaults to the m3u8 filename.",
    )
    parser.add_argument(
        "--header",
        action="append",
        default=[],
        help='HTTP header passed to ffmpeg, e.g. --header "Referer: https://example.com"',
    )
    parser.add_argument(
        "--no-overwrite",
        action="store_true",
        help="Do not overwrite the output file if it already exists.",
    )
    parser.add_argument(
        "--quality",
        choices=sorted(QUALITY_HEIGHTS),
        help="Prefer a 720p or 1080p variant when the m3u8 master playlist offers one.",
    )
    parser.add_argument(
        "--segment-workers",
        type=int,
        default=DEFAULT_SEGMENT_WORKERS,
        help=f"Concurrent segment downloads. Default: {DEFAULT_SEGMENT_WORKERS}.",
    )
    parser.add_argument(
        "--retries",
        type=int,
        default=DEFAULT_RETRIES,
        help=f"Download attempts for playlist and segment timeouts. Default: {DEFAULT_RETRIES}.",
    )
    parser.add_argument(
        "--timeout",
        type=int,
        default=DEFAULT_TIMEOUT,
        help=f"Per-request timeout in seconds. Default: {DEFAULT_TIMEOUT}.",
    )
    return parser.parse_args(argv)


def download(argv: list[str]) -> int:
    args = parse_args(argv)
    url = validate_source(args.url)
    output_path = normalize_output_path(args.output) if args.output else default_output_path(url)
    os.makedirs(os.path.dirname(os.path.abspath(output_path)), exist_ok=True)
    ffmpeg_path = find_ffmpeg()
    preferred_height = QUALITY_HEIGHTS[args.quality] if args.quality else None
    print("preparing cleaned local HLS segments...", file=sys.stderr)
    with tempfile.TemporaryDirectory(prefix="download_m3u8_") as work_dir:
        cleaned_playlist = prepare_clean_hls_playlist(
            url=url,
            headers=args.header,
            work_dir=work_dir,
            preferred_height=preferred_height,
            segment_workers=args.segment_workers,
            timeout=args.timeout,
            retries=args.retries,
        )
        command = build_ffmpeg_command(
            ffmpeg_path=ffmpeg_path,
            url=cleaned_playlist,
            output_path=output_path,
            headers=None,
            overwrite=not args.no_overwrite,
        )
        completed = subprocess.run(command)

    if completed.returncode != 0:
        return completed.returncode

    print(f"Saved MP4 to: {os.path.abspath(output_path)}")
    return 0


def main() -> int:
    try:
        return download(sys.argv[1:])
    except (RuntimeError, ValueError) as error:
        print(f"error: {error}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
