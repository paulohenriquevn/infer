"""Generate architecture.drawio: the target AWS architecture for GLM-5.3-Flash serving.

Usage: python3 generate_drawio.py architecture.drawio
Edit the labels here and regenerate; export with draw.io: drawio -x -f png -s 1.5 -o architecture.png architecture.drawio
"""
import xml.etree.ElementTree as ET, sys
out = sys.argv[1]
mx = ET.Element("mxfile", host="drawio")
d = ET.SubElement(mx, "diagram", id="arq", name="GLM-5.3-Flash on AWS")
m = ET.SubElement(d, "mxGraphModel", dx="1800", dy="1300", grid="1", gridSize="10", guides="1",
                  tooltips="1", connect="1", arrows="1", fold="1", page="1", pageScale="1",
                  pageWidth="1820", pageHeight="1290", math="0", shadow="0")
root = ET.SubElement(m, "root")
ET.SubElement(root, "mxCell", id="0"); ET.SubElement(root, "mxCell", id="1", parent="0")
n = [0]
def cell(value, style, x, y, w, h, cid=None):
    n[0] += 1; cid = cid or f"c{n[0]}"
    c = ET.SubElement(root, "mxCell", id=cid, value=value, style=style, vertex="1", parent="1")
    ET.SubElement(c, "mxGeometry", x=str(x), y=str(y), width=str(w), height=str(h), **{"as": "geometry"})
    return cid
def edge(src, dst, label="", style="", pts=None, lx=None):
    n[0] += 1; cid = f"e{n[0]}"
    base = "edgeStyle=orthogonalEdgeStyle;rounded=1;orthogonalLoop=1;jettySize=auto;html=1;strokeWidth=2;fontSize=11;labelBackgroundColor=#ffffff;endArrow=block;endFill=1;"
    c = ET.SubElement(root, "mxCell", id=cid, value=label, style=base + style, edge="1", parent="1", source=src, target=dst)
    g = ET.SubElement(c, "mxGeometry", relative="1", **({"x": lx} if lx else {}), **{"as": "geometry"})
    if pts:
        a = ET.SubElement(g, "Array", **{"as": "points"})
        for px, py in pts: ET.SubElement(a, "mxPoint", x=str(px), y=str(py))
    return cid

GRP = "points=[];outlineConnect=0;gradientColor=none;html=1;whiteSpace=wrap;fontSize=13;fontStyle=1;container=0;pointerEvents=0;collapsible=0;recursiveResize=0;shape=mxgraph.aws4.group;verticalAlign=top;align=left;spacingLeft=30;"
def icon(res, color, label, x, y, size=56):
    st = (f"sketch=0;points=[];outlineConnect=0;fontColor=#232F3E;fillColor={color};strokeColor=#ffffff;dashed=0;"
          "verticalLabelPosition=bottom;verticalAlign=top;align=center;html=1;fontSize=11;fontStyle=0;aspect=fixed;"
          f"shape=mxgraph.aws4.resourceIcon;resIcon=mxgraph.aws4.{res};whiteSpace=wrap;labelWidth=170;")
    return cell(label, st, x, y, size, size)
DEC = "rounded=1;whiteSpace=wrap;html=1;fontSize=12;arcSize=8;strokeWidth=2;strokeColor=#232F3E;fillColor=#FFFFFF;"
PROP = "rounded=1;whiteSpace=wrap;html=1;fontSize=12;arcSize=8;strokeWidth=2;strokeColor=#1F5F8B;dashed=1;dashPattern=8 4;fillColor=#EAF2F8;"
OPEN = "rounded=1;whiteSpace=wrap;html=1;fontSize=12;arcSize=8;strokeWidth=2;strokeColor=#A86400;fillColor=#FBF0DC;"
LATER = "rounded=1;whiteSpace=wrap;html=1;fontSize=12;arcSize=8;strokeWidth=2;strokeColor=#7F8C8D;dashed=1;dashPattern=2 3;fillColor=#ECEEEF;fontColor=#555555;"
GPU = "rounded=0;whiteSpace=wrap;html=1;fontSize=12;strokeWidth=2;strokeColor=#3B4F1F;fillColor=#EEF3E2;"
LANE = "rounded=0;whiteSpace=wrap;html=1;fontSize=13;fontStyle=1;verticalAlign=top;align=left;spacingLeft=10;spacingTop=4;strokeColor=#9AA6B2;fillColor=#F7F8F9;dashed=0;"

# title
cell("<b style='font-size:22px'>GLM-5.3-Flash for coding agents on AWS</b><br>"
     "<span style='font-size:12px'>Target architecture · state on 2026-11-12 · docs/06-aws-implementation-plan.md</span>",
     "text;html=1;align=left;verticalAlign=top;whiteSpace=wrap;", 20, 10, 900, 60)

# external sources (top right)
cell("Internet: external sources", LANE, 1000, 10, 780, 100)
hf = cell("<b>Hugging Face Hub</b><br>QAD NVFP4-MXFP8 checkpoint<br>revision dec48abd (177.7 GB)", DEC, 1020, 40, 230, 60)
gh = cell("<b>ghcr.io</b><br>vllm:karmic-kraken-20261016<br>pinned by digest sha256:c14295c2…", DEC, 1270, 40, 250, 60)
nv = cell("<b>NVIDIA repository</b><br>driver ≥ 615.65.02 +<br>Container Toolkit", OPEN, 1540, 40, 220, 60)

# clients (left)
cell("Clients (outside AWS)", LANE, 20, 140, 200, 420)
users = cell("<b>~10,000 developers</b>", "sketch=0;outlineConnect=0;fontColor=#232F3E;gradientColor=none;fillColor=#232F3E;strokeColor=none;dashed=0;verticalLabelPosition=bottom;verticalAlign=top;align=center;html=1;fontSize=12;aspect=fixed;shape=mxgraph.aws4.users;", 81, 190, 78, 78)
agents = cell("<b>Coding agents</b><br>tool loop, sub-agent bursts<br><font face='monospace'>/v1/chat/completions</font><br>(OpenAI API, streaming)", DEC, 35, 320, 170, 110)
cell("98.6% of tokens are input;<br>burst p99 = 175 requests", "text;html=1;align=center;fontSize=11;fontColor=#5B6672;whiteSpace=wrap;", 35, 450, 170, 40)

# AWS cloud, region, VPC, AZ
cell("AWS Cloud", GRP + "grIcon=mxgraph.aws4.group_aws_cloud_alt;strokeColor=#232F3E;fillColor=none;fontColor=#232F3E;dashed=0;", 250, 130, 1530, 930)
cell("AWS Region (open · candidate us-east-1, G7e in 1b/1c/1d on 2026-11-04)", GRP + "grIcon=mxgraph.aws4.group_region;strokeColor=#00A4A6;fillColor=none;fontColor=#147EBA;dashed=1;", 270, 170, 1490, 870)
elb = icon("elastic_load_balancing", "#8C4FFF", "<b>Load balancer</b><br>TLS, public endpoint<br><font color='#A86400'>open · phase 5</font>", 312, 300, 60)
cell("VPC (default in phases 1 and 2, dedicated in phase 3) · proposed", GRP + "grIcon=mxgraph.aws4.group_vpc2;strokeColor=#8C4FFF;fillColor=none;fontColor=#8C4FFF;dashed=0;", 450, 210, 1290, 590)
cell("Availability Zone with G7e capacity", "fillColor=none;strokeColor=#147EBA;dashed=1;verticalAlign=top;fontStyle=0;fontColor=#147EBA;whiteSpace=wrap;html=1;fontSize=12;align=left;spacingLeft=10;", 470, 250, 1250, 530)
cell("Private subnet · inference cell (no inbound port; admin through SSM)", GRP + "grIcon=mxgraph.aws4.group_private_subnet;strokeColor=#00A4A6;fillColor=#E6F6F7;fontColor=#147EBA;dashed=0;", 490, 290, 950, 470)
cell("Public subnet", GRP + "grIcon=mxgraph.aws4.group_public_subnet;strokeColor=#7AA116;fillColor=#F2F6E8;fontColor=#248814;dashed=0;", 1460, 290, 240, 190)
nat = icon("nat_gateway", "#8C4FFF", "<b>NAT gateway</b><br>egress to ghcr.io and HF<br><font color='#1F5F8B'>proposed</font>", 1550, 340, 56)
s3ep = cell("<b>S3 gateway endpoint</b><br>weights without the internet<br><font color='#1F5F8B'>proposed · phase 3</font>",
            "sketch=0;outlineConnect=0;fontColor=#232F3E;gradientColor=none;fillColor=#8C4FFF;strokeColor=none;dashed=0;verticalLabelPosition=bottom;verticalAlign=top;align=center;html=1;fontSize=11;aspect=fixed;shape=mxgraph.aws4.endpoints;labelWidth=190;", 1552, 540, 52, 52)

# gateway and router
gw = cell("<b>Auth and quota gateway</b><br>identity, per-user quota and concurrency, session ID<br><font color='#A86400'>tool open · phase 5</font>", OPEN, 510, 330, 190, 100)
cell("EC2 router · phase 3", GRP + "grIcon=mxgraph.aws4.group_ec2_instance_contents;strokeColor=#D86613;fillColor=none;fontColor=#D86613;dashed=1;", 510, 460, 190, 280)
envoy = cell("<b>Envoy</b><br>data proxy<br><font color='#1F5F8B'>proposed</font>", PROP, 530, 500, 150, 60)
epp = cell("<b>llm-d EPP v1.0.0</b><br>approximate prefix affinity + token load, saturation detector<br>file-based discovery (no K8s)", DEC, 530, 590, 150, 110)

# replica 1
cell("g7e.24xlarge · replica 1 (decided)", GRP + "grIcon=mxgraph.aws4.group_ec2_instance_contents;strokeColor=#D86613;fillColor=#FFFFFF;fontColor=#D86613;dashed=0;", 740, 320, 450, 430)
r = []
rows = [
 (DEC, "<b>vLLM fork</b> (local-inference-lab) in Docker · port 8000 · /metrics<br>TP4 · MTP 3 tokens · max-num-batched-tokens 4096 · 32 seqs · block 2048"),
 (DEC, "<b>GLM-5.3-Flash QAD NVFP4-MXFP8</b><br>320B total / 18B active · 34 KDA + 11 sparse MLA · MoE 288/8"),
 (OPEN, "<b>DCP1</b> (24 sessions inside the SLO, one run) <b>or DCP4</b> (8 sessions)<br>decided in phase 2"),
 (DEC, "<b>KV in HBM</b>: prefix cache, ~97% hit per turn"),
 (PROP, "<b>LMCache L1 in RAM</b> (/dev/shm, 1,024 GiB host): restores idle sessions · tested in phase 4"),
 (PROP, "<b>NVMe instance store 2 × 3.8 TB</b>: weights and JIT cache"),
]
y = 360
for st, txt in rows:
    r.append(cell(txt, st + "align=left;spacingLeft=8;", 760, y, 410, 42)); y += 48
gy = y + 2
for i in range(4):
    cell(f"<b>GPU {i}</b><br>RTX PRO 6000<br>96 GB", GPU, 760 + i * 104, gy, 98, 38 + 12)
cell("PCIe Gen5 · P2P · all-reduce B12X", "text;html=1;align=center;fontSize=10;fontColor=#3B4F1F;", 760, gy + 52, 410, 14)
rep1 = r[0]

# replica N
cell("g7e.24xlarge · replica N", GRP + "grIcon=mxgraph.aws4.group_ec2_instance_contents;strokeColor=#D86613;fillColor=#FFFFFF;fontColor=#D86613;dashed=0;", 1220, 320, 200, 430)
repn = cell("<b>× N identical replicas</b><br><br>same image, checkpoint and flags<br><br>2 in phase 3<br>~56 in the base fleet<br><font color='#A86400'>(provisional, depends on phase 2)</font>", DEC, 1240, 380, 160, 200)
ec2icon = icon("ec2", "#ED7100", "launch template + user data", 1296, 620, 48)

# regional services
yy = 860
s3w = icon("s3", "#7AA116", "<b>S3: weights mirror</b><br><font color='#1F5F8B'>proposed · phase 1</font>", 330, yy)
s3t = icon("s3", "#7AA116", "<b>S3: Terraform state</b><br>use_lockfile · versioned<br><font color='#2C6E49'>decided</font>", 520, yy)
iam = icon("identity_and_access_management", "#DD344C", "<b>IAM instance profile</b><br>S3 read, no keys<br><font color='#1F5F8B'>proposed</font>", 710, yy)
ssm = icon("systems_manager", "#E7157B", "<b>SSM Session Manager</b><br>access without SSH<br><font color='#1F5F8B'>proposed</font>", 900, yy)
prom = icon("cloudwatch_2", "#E7157B", "<b>Prometheus + dashboards</b><br>TTFT p95, tok/s, queue, KV<br><font color='#A86400'>tool open · phase 5</font>", 1090, yy)
eks = icon("eks", "#ED7100", "<b>EKS + KEDA</b><br>scales on queue, KV and sessions,<br>never on GPU %<br><font color='#1F5F8B'>proposed · phase 5</font>", 1280, yy)
bud = icon("budgets", "#7AA116", "<b>AWS Budgets + tags</b><br>cost alarm, teardown<br><font color='#1F5F8B'>proposed</font>", 1470, yy)
cell("Regional services", "text;html=1;align=left;fontSize=12;fontStyle=1;fontColor=#147EBA;", 290, 825, 200, 20)
cell("<b>Purchase</b>: on-demand US$ 16.57/h in phases 1 to 4;<br>3-year Savings Plan US$ 7.16/h is the candidate<br><font color='#A86400'>open</font>",
     OPEN + "fontSize=11;align=left;spacingLeft=6;", 1590, 850, 170, 80)

# engineering (bottom)
cell("Engineering, measurement and operations (off the request path)", LANE, 250, 1080, 1530, 130)
tf = cell("<b>Terraform</b> + provider AWS<br>infra/aws: network, IAM, launch template, replicas<br><font color='#2C6E49'>decided</font>", DEC, 270, 1115, 260, 80)
bench = cell("<b>Harness bench/</b><br>quality gate: needle 500 runs, Fisher vs 3/500, gsm8k; agent levels vs SLO", DEC, 550, 1115, 300, 80)
qual = cell("<b>Host qualification</b><br>P2P, driver, B12X log line, C32 ≥ 1,400 tok/s (DCP1)", DEC, 870, 1115, 230, 80)
cc = cell("<b>Claude Code (.claude/)</b><br>10 skills, 5 agents, 5 commands, hooks that confirm before spending", DEC, 1120, 1115, 260, 80)
vast = cell("<b>Vast.ai</b><br>cheap measurement runs", DEC, 1400, 1115, 160, 80)
ghrel = cell("<b>GitHub</b><br>repo + release evidence-2026-11-12", DEC, 1580, 1115, 180, 80)

# legend
cell("Legend", LANE, 20, 600, 200, 370)
cell("Decided", DEC, 40, 640, 160, 34)
cell("Proposed (phase plan)", PROP, 40, 684, 160, 34)
cell("Open", OPEN, 40, 728, 160, 34)
cell("Not in the first design", LATER, 40, 772, 160, 34)
cell("<b>① to ⑥</b> path of one turn: ③ carries the session ID; ⑤ goes to the replica that holds the prefix<br>dashed = control, weights or image", "text;html=1;align=left;fontSize=11;whiteSpace=wrap;", 30, 812, 185, 72)
cell("<b>Not in the first design:</b> P/D with NIXL over EFA; LMCache L2 (FSx for Lustre?); SGLang (rejected)", LATER + "fontSize=11;", 30, 900, 180, 55)

# SLO
cell("<b>SLO</b>: zero errors · TTFT p95 ≤ 5 s on cached turns · ≥ 30 tok/s p50 per stream<br><b>Metric</b>: sessions inside the SLO per US$/h (4.28 Observed on Vast; ~3.35 Inferred on AWS with a 3-year Savings Plan)",
     "rounded=0;whiteSpace=wrap;html=1;fontSize=12;strokeColor=#2C6E49;fillColor=#E2F0E7;align=left;spacingLeft=10;", 20, 1220, 1760, 46)

# request path edges
edge(users, agents, "")
edge(agents, elb, "① HTTPS", "strokeColor=#1F5F8B;", [(270, 375), (270, 330)])
edge(elb, gw, "②", "strokeColor=#1F5F8B;")
edge(gw, envoy, "③", "strokeColor=#1F5F8B;", lx="-0.6")
edge(envoy, epp, "④ ext-proc", "strokeColor=#1F5F8B;dashed=1;startArrow=block;startFill=1;")
edge(envoy, rep1, "⑤", "strokeColor=#1F5F8B;", [(720, 530), (720, 381)])
edge(envoy, repn, "", "strokeColor=#1F5F8B;", [(720, 530), (720, 765), (1205, 765), (1205, 480)])
cell("<b>⑥</b> prefill of new tokens only, MTP decode, streamed response", "text;html=1;align=center;fontSize=11;fontColor=#1F5F8B;whiteSpace=wrap;", 760, 720, 410, 28)
# data and control
edge(r[5], s3ep, "weights at first start", "dashed=1;strokeColor=#7AA116;strokeWidth=1.5;", [(1200, 621), (1200, 600), (1530, 600), (1530, 566)])
edge(s3ep, s3w, "", "dashed=1;strokeColor=#7AA116;strokeWidth=1.5;", [(1578, 818), (358, 818)])
edge(nat, gh, "image", "dashed=1;strokeColor=#5B6672;strokeWidth=1.5;exitX=0.3;exitY=0;exitDx=0;exitDy=0;", [(1566, 155), (1395, 155)])
edge(nat, hf, "weights (mirror)", "dashed=1;strokeColor=#5B6672;strokeWidth=1.5;exitX=0.7;exitY=0;exitDx=0;exitDy=0;", [(1589, 143), (1135, 143)])
edge(tf, s3t, "state", "dashed=1;strokeColor=#5B6672;strokeWidth=1.5;", [(400, 1070), (548, 1070)])
ET.ElementTree(mx).write(out, encoding="utf-8", xml_declaration=False)
