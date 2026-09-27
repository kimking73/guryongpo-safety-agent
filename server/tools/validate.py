import yaml, json, re, jsonschema
from jsonschema import Draft202012Validator
d = yaml.safe_load(open('../spec/openapi.yaml'))
# 1) ref / path param check
errs=[]
def walk(o):
    if isinstance(o,dict):
        for k,v in o.items():
            if k=='$ref':
                t=d
                try:
                    for x in v.lstrip('#/').split('/'): t=t[x]
                except KeyError: errs.append('bad ref '+v)
            else: walk(v)
    elif isinstance(o,list):
        for v in o: walk(v)
walk(d)
ops=0
for p,item in d['paths'].items():
    need=set(re.findall(r'{(\w+)}',p)); common={x['name'] for x in item.get('parameters',[]) if 'name' in x}
    for m,op in item.items():
        if m=='parameters': continue
        ops+=1
        have=common|{x.get('name') or d['components']['parameters'][x['$ref'].split('/')[-1]]['name'] for x in op.get('parameters',[])}
        if need-have: errs.append(f'{m} {p} missing {need-have}')
print(len(d['paths']),'paths',ops,'operations; structural errors:',errs or 'none')
# 2) mocks vs response schemas
M={'health.json':('/health','get','200','application/json'),
 'user.json':('/user','get','200','application/json'),
 'device-token.json':('/device-token','post','200','application/json'),
 'dashboard.normal.json':('/dashboard','get','200','application/json'),
 'dashboard.emergency.json':('/dashboard','get','200','application/json'),
 'layer.shelters.geojson':('/dashboard/layers/{layer_id}','get','200','application/geo+json'),
 'layer.stations.geojson':('/dashboard/layers/{layer_id}','get','200','application/geo+json'),
 'risk.json':('/risk','get','200','application/json'),
 'risk-areas.geojson':('/risk/areas','get','200','application/geo+json'),
 'alerts.json':('/alerts','get','200','application/json'),
 'chat.json':('/chat','post','200','application/json'),
 'voice.json':('/voice','post','200','application/json'),
 'route.json':('/route','post','200','application/json'),
 'route-check.json':('/route/check','post','200','application/json')}
bad=0
for f,(p,m,s,ct) in M.items():
    sch=d['paths'][p][m]['responses'][s]['content'][ct]['schema']
    root=dict(d); root.update(sch)
    data=json.load(open('../mock/'+f))
    es=list(Draft202012Validator(root, format_checker=Draft202012Validator.FORMAT_CHECKER).iter_errors(data))
    print(('OK  ' if not es else 'FAIL'), f, *[f'\n    {e.json_path}: {e.message[:120]}' for e in es[:5]])
    bad+=bool(es)
# extra: RiskItem in risk-areas properties
ri=dict(d); ri.update({'$ref':'#/components/schemas/RiskItem'})
for ft in json.load(open('../mock/risk-areas.geojson'))['features']:
    for e in Draft202012Validator(ri).iter_errors(ft['properties']): print('RiskItem FAIL',e.message); bad+=1
print('mock failures:',bad)
