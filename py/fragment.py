import json
import sys

config_file = sys.argv[1]
interval = sys.argv[2]
length = sys.argv[3]
packets = sys.argv[4]

with open(config_file, 'r') as f:
    config = json.load(f)

# Find and update fragment outbound
for outbound in config.get('outbounds', []):
    if outbound.get('tag') == 'fragment':
        if 'settings' not in outbound:
            outbound['settings'] = {}
        if 'fragment' not in outbound['settings']:
            outbound['settings']['fragment'] = {}
        
        outbound['settings']['fragment']['interval'] = interval
        outbound['settings']['fragment']['length'] = length
        outbound['settings']['fragment']['packets'] = packets

with open(config_file, 'w') as f:
    json.dump(config, f, indent=2)