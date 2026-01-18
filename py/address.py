import json
import sys

config_file = sys.argv[1]
address = sys.argv[2]

with open(config_file, 'r') as f:
    config = json.load(f)

# Find and update outbound address
for outbound in config.get('outbounds', []):
    if outbound.get('protocol') == 'vless':
        if 'settings' not in outbound:
            continue
        if 'vnext' not in outbound['settings']:
            continue
        for i in range(len(outbound['settings']['vnext'])):
            outbound['settings']['vnext'][i]['address'] = address

with open(config_file, 'w') as f:
    json.dump(config, f, indent=2)