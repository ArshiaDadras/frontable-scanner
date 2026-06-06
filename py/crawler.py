import asyncio
import json
import re
import signal
from pathlib import Path

import aiohttp

# ---------------------------------------------------
# CONFIG
# ---------------------------------------------------

ASN_SOURCE_URL = "https://www.cidr-report.org/as2.0/autnums.html"
OUTPUT_FILE = Path("asn_data.json")

MAX_CONCURRENT = 30
MAX_ASNS_PER_RUN = None

IPV4_CIDR_RE = re.compile(r"^(?:\d{1,3}\.){3}\d{1,3}/\d{1,2}$")
IPV6_CIDR_RE = re.compile(r"^[0-9a-fA-F:]+/\d{1,3}$")

shutdown_event = asyncio.Event()

# ---------------------------------------------------
# FETCH ASN LIST
# ---------------------------------------------------

async def fetch_all_asns():
    print("[*] Fetching ASN list...")
    async with aiohttp.ClientSession() as session:
        async with session.get(ASN_SOURCE_URL) as resp:
            resp.raise_for_status()
            text = await resp.text()

    asns = sorted(set(re.findall(r"\bAS\d+\b", text)))
    print(f"[+] Found {len(asns)} ASNs")
    return asns

# ---------------------------------------------------
# LOAD / SAVE
# ---------------------------------------------------

def load_existing_data():
    if not OUTPUT_FILE.exists():
        return {}
    try:
        return json.loads(OUTPUT_FILE.read_text("utf-8"))
    except Exception:
        return {}

def save_data(data):
    tmp = OUTPUT_FILE.with_suffix(".tmp")
    tmp.write_text(json.dumps(data, indent=2, ensure_ascii=False), encoding="utf-8")
    tmp.replace(OUTPUT_FILE)

# ---------------------------------------------------
# WHOIS QUERY
# ---------------------------------------------------

async def whois_query(query: str):
    reader, writer = await asyncio.open_connection("whois.radb.net", 43)

    try:
        writer.write((query + "\r\n").encode())
        await writer.drain()

        data = b""
        while True:
            chunk = await reader.read(4096)
            if not chunk:
                break
            data += chunk

        return data.decode(errors="ignore")

    finally:
        writer.close()
        await writer.wait_closed()

# ---------------------------------------------------
# ASN PARSER (FIXED)
# ---------------------------------------------------

async def fetch_asn(asn: str, semaphore):
    if shutdown_event.is_set():
        return None

    async with semaphore:

        try:
            print(f"[*] Querying {asn}")

            raw = await whois_query(f"-i origin {asn}")

            netblocks = {}
            asn_name = None

            current_prefix = None

            for line in raw.splitlines():
                line = line.strip()

                # PREFIXES
                if line.startswith("route:"):
                    current_prefix = line.split(":", 1)[1].strip()

                elif line.startswith("route6:"):
                    current_prefix = line.split(":", 1)[1].strip()

                # DESCRIPTION (THIS WAS MISSING BEFORE)
                elif line.startswith("descr:") and current_prefix:
                    descr = line.split(":", 1)[1].strip()

                    if (
                        IPV4_CIDR_RE.match(current_prefix)
                        or IPV6_CIDR_RE.match(current_prefix)
                    ):
                        netblocks[current_prefix] = descr

                    current_prefix = None

                # FALLBACK NAME
                elif line.startswith("org-name:") and not asn_name:
                    asn_name = line.split(":", 1)[1].strip()

            if not netblocks:
                return None

            # fallback name if missing
            if not asn_name:
                asn_name = next(iter(netblocks.values()))

            print(f"[+] {asn} -> {len(netblocks)} prefixes")

            return {
                "id": asn,
                "name": asn_name,
                "netblocks": netblocks
            }

        except Exception as e:
            print(f"[!] Error {asn}: {e}")
            return None

# ---------------------------------------------------
# MAIN
# ---------------------------------------------------

async def main():
    existing = load_existing_data()
    existing_asns = set(existing.keys())

    async with aiohttp.ClientSession() as session:

        async with session.get(ASN_SOURCE_URL) as resp:
            text = await resp.text()

    all_asns = sorted(set(re.findall(r"\bAS\d+\b", text)))

    pending = [a for a in all_asns if a not in existing_asns]

    if MAX_ASNS_PER_RUN:
        pending = pending[:MAX_ASNS_PER_RUN]

    print(f"[+] Remaining ASNs: {len(pending)}")

    sem = asyncio.Semaphore(MAX_CONCURRENT)

    tasks = [fetch_asn(a, sem) for a in pending]

    done = 0

    for t in asyncio.as_completed(tasks):

        if shutdown_event.is_set():
            break

        result = await t
        done += 1

        print(f"[{done}/{len(tasks)}] processed")

        if not result:
            continue

        existing[f"{result['id']} {result['name']}"] = {
            "id": result["id"],
            "name": result["name"],
            "netblocks": result["netblocks"]
        }

        save_data(existing)

    print(f"[✓] Done: {len(existing)} ASNs saved")

# ---------------------------------------------------
# SHUTDOWN
# ---------------------------------------------------

def setup_shutdown():
    def handler():
        print("\n[!] Shutdown requested")
        shutdown_event.set()

    loop = asyncio.get_running_loop()

    for sig in (signal.SIGINT, signal.SIGTERM):
        try:
            loop.add_signal_handler(sig, handler)
        except NotImplementedError:
            signal.signal(sig, lambda s, f: handler())

# ---------------------------------------------------
# ENTRY
# ---------------------------------------------------

if __name__ == "__main__":
    asyncio.run(main())