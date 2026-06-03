"""Groove Player webapp.

Left sidebar = two SEPARATE scrollable groove lists:
  * "Google Groove Dataset" -- read-only, extracted from the GMD MIDI.
  * "My Swing Files"         -- grooves YOU create by analyzing audio.

You can play the raw source audio (Amen break, straight target), analyze the
Amen into a new swing file (added only to *your* list), pick any groove from
either list, set a swing amount, and play it stamped onto straight_target.wav.

Run:  uv run python webapp.py   ->  http://127.0.0.1:5001
"""
import hashlib
import json
import os

from flask import Flask, jsonify, request, send_file, Response

from mgm import (
    groove_from_offsets, GrooveMap, render_grooved_audio,
    extract_groove_from_audio,
)

ROOT = os.path.dirname(__file__)
EXAMPLES = os.path.join(ROOT, "examples")
TARGET = os.path.join(EXAMPLES, "straight_target.wav")
AMEN = os.path.join(EXAMPLES, "amen.wav")
GOOGLE = json.load(open(os.path.join(EXAMPLES, "groove_library.json")))
# Cache / user-data paths are env-overridable so hosts (e.g. Hugging Face
# Spaces, where the app dir is read-only) can point them at a writable dir.
USER_PATH = os.environ.get("MGM_USER", os.path.join(EXAMPLES, "user_grooves.json"))
USER = json.load(open(USER_PATH)) if os.path.exists(USER_PATH) else []
CACHE = os.environ.get("MGM_CACHE", os.path.join(EXAMPLES, "_cache"))
os.makedirs(CACHE, exist_ok=True)

# Named raw audio the UI can play directly (unmodified).
RAW = {"amen": AMEN, "target": TARGET}

app = Flask(__name__)


def get_groove(gid: str) -> dict:
    """Resolve an id like 'g3' / 'u0' to its groove dict."""
    kind, idx = gid[0], int(gid[1:])
    return (GOOGLE if kind == "g" else USER)[idx]


def render_for(gid: str, dial: int) -> str:
    g = get_groove(gid)
    sig = hashlib.md5(f"{gid}-{dial}-{g['timing']}".encode()).hexdigest()[:12]
    out = os.path.join(CACHE, f"{sig}.wav")
    if not os.path.exists(out):
        straight = groove_from_offsets([0] * len(g["timing"]), "4/4",
                                       g["subdivision"], unit="ms")
        full = groove_from_offsets(g["timing"], "4/4", g["subdivision"], unit="ms")
        gmap = GrooveMap({0: straight, 127: full})
        render_grooved_audio(TARGET, gmap.resolve(dial), out)
    return out


def analyze_amen() -> dict:
    """Extract an accurate swing array from amen.wav via the MGM extractor."""
    groove = extract_groove_from_audio(
        AMEN, time_signature="4/4", subdivision=16, unit="ms", tempo_bpm=137.2)
    timing = [round(v, 2) for v in groove.timing]
    entry = {
        "name": f"Amen swing #{len(USER) + 1}", "style": "user",
        "bpm": 137, "subdivision": 16, "time_signature": "4/4",
        "unit": "ms", "timing": timing,
    }
    USER.append(entry)
    json.dump(USER, open(USER_PATH, "w"), indent=2)
    return entry


# ---- routes ---------------------------------------------------------------
@app.route("/")
def index():
    return Response(PAGE, mimetype="text/html")


@app.route("/grooves")
def grooves():
    def pack(lst, kind):
        return [{"id": f"{kind}{i}", "name": g["name"], "style": g["style"],
                 "bpm": g["bpm"], "timing": g["timing"]} for i, g in enumerate(lst)]
    return jsonify({"google": pack(GOOGLE, "g"), "user": pack(USER, "u")})


@app.route("/analyze", methods=["POST"])
def analyze():
    entry = analyze_amen()
    return jsonify({"id": f"u{len(USER) - 1}", "name": entry["name"],
                    "style": entry["style"], "bpm": entry["bpm"],
                    "timing": entry["timing"]})


@app.route("/raw")
def raw():
    name = request.args.get("name", "")
    if name not in RAW:
        return ("unknown", 404)
    return send_file(RAW[name], mimetype="audio/wav", conditional=True)


@app.route("/audio")
def audio():
    gid = request.args.get("id", "g0")
    dial = max(0, min(127, int(request.args.get("dial", 127))))
    return send_file(render_for(gid, dial), mimetype="audio/wav", conditional=True)


PAGE = r"""<!doctype html>
<html><head><meta charset="utf-8"><title>Groove Player</title>
<style>
  *{box-sizing:border-box}
  body{font-family:-apple-system,Segoe UI,sans-serif;margin:0;background:#11131a;
       color:#e7e9ee;display:flex;height:100vh}
  #side{width:300px;flex:none;border-right:1px solid #232733;display:flex;
        flex-direction:column;background:#15171f}
  #side h2{font-size:12px;text-transform:uppercase;letter-spacing:1px;color:#8b90a0;
           margin:0;padding:14px 16px 8px}
  .list{overflow-y:auto;flex:1 1 0;min-height:60px}
  .list.user{flex:0 0 34%;border-top:1px solid #232733}
  .item{padding:9px 16px;font-size:13px;cursor:pointer;border-left:3px solid transparent}
  .item:hover{background:#1c1f29}
  .item.sel{background:#23304f;border-left-color:#3b6cf6;color:#cdd8ff}
  .item small{color:#787e90;display:block}
  #main{flex:1;padding:34px 40px;overflow-y:auto}
  h1{font-weight:700;letter-spacing:-.5px;margin:0 0 4px}
  .sub{color:#8b90a0;margin:0 0 24px}
  button{font-size:14px;padding:9px 14px;border-radius:9px;border:1px solid #2b2f3a;
         background:#1b1e27;color:#e7e9ee;cursor:pointer}
  button.primary{background:#3b6cf6;border:none;font-weight:600}
  button.accent{background:#1f6f4a;border:none;font-weight:600}
  button:active{transform:translateY(1px)}
  .row{display:flex;gap:10px;align-items:center;margin:14px 0;flex-wrap:wrap}
  label{color:#8b90a0;font-size:13px}
  input[type=range]{width:240px;accent-color:#3b6cf6}
  #bars{display:flex;gap:3px;height:90px;align-items:center;margin-top:24px;max-width:560px}
  .bar{flex:1;background:#3b6cf6;border-radius:3px;min-height:2px;opacity:.85}
  .bar.neg{background:#f6713b}
  code{color:#9fb4ff}
  .card{background:#161922;border:1px solid #232733;border-radius:12px;padding:18px 20px;
        max-width:600px;margin-bottom:18px}
  #status{color:#8b90a0;font-size:13px}
</style></head><body>

<div id="side">
  <h2>Google Groove Dataset</h2>
  <div class="list" id="glist"></div>
  <h2>My Swing Files</h2>
  <div class="list user" id="ulist"></div>
</div>

<div id="main">
  <h1>Groove Player</h1>
  <p class="sub">Stamp a groove onto <code>straight_target.wav</code> and play it.</p>

  <div class="card">
    <strong>Source audio</strong>
    <div class="row">
      <button onclick="playRaw('amen')">▶ Play Amen break</button>
      <button onclick="playRaw('target')">▶ Play straight target</button>
      <button class="accent" id="analyze">⚙ Analyze Amen → add swing file</button>
    </div>
  </div>

  <div class="card">
    <strong>Selected groove: <span id="selname">— none —</span></strong>
    <div class="row">
      <label>Swing amount</label>
      <input type="range" id="dial" min="0" max="127" value="127">
      <span id="dialval">127</span>
    </div>
    <div class="row">
      <button class="primary" id="play">▶ Play with groove</button>
      <span id="status"></span>
    </div>
    <div id="bars" title="per-16th timing offset (blue = late, orange = early)"></div>
  </div>
</div>

<audio id="player"></audio>
<script>
let data={google:[],user:[]}, sel=null;
const player=document.getElementById('player'),
      dial=document.getElementById('dial'), dialval=document.getElementById('dialval'),
      status=document.getElementById('status'), bars=document.getElementById('bars'),
      selname=document.getElementById('selname');

function drawBars(timing){
  bars.innerHTML='';
  const max=Math.max(30,...timing.map(v=>Math.abs(v)));
  timing.forEach(v=>{const b=document.createElement('div');
    b.className='bar'+(v<0?' neg':'');
    b.style.height=(4+Math.abs(v)/max*82)+'px'; bars.appendChild(b);});
}
function byId(id){ return [...data.google,...data.user].find(g=>g.id===id); }
function select(id){
  sel=id; const g=byId(id);
  selname.textContent=g.name; drawBars(g.timing);
  document.querySelectorAll('.item').forEach(e=>
    e.classList.toggle('sel', e.dataset.id===id));
}
function renderList(el, items){
  el.innerHTML='';
  items.forEach(g=>{const d=document.createElement('div');
    d.className='item'; d.dataset.id=g.id;
    d.innerHTML=`${g.name}<small>${g.style}${g.bpm?' · '+g.bpm+' bpm':''}</small>`;
    d.onclick=()=>select(g.id); el.appendChild(d);});
}
function refresh(){
  return fetch('/grooves').then(r=>r.json()).then(d=>{data=d;
    renderList(document.getElementById('glist'), d.google);
    renderList(document.getElementById('ulist'), d.user);
    if(d.user.length===0)
      document.getElementById('ulist').innerHTML=
        '<div style="padding:12px 16px;color:#5a5f6e;font-size:12px">Analyze the Amen to create one.</div>';
  });
}

dial.oninput=()=>dialval.textContent=dial.value;

function playRaw(name){
  status.textContent='playing source: '+name;
  player.src='/raw?name='+name+'&t='+Date.now(); player.play();
}
document.getElementById('play').onclick=async()=>{
  if(!sel){ status.textContent='pick a groove on the left first'; return; }
  status.textContent='rendering…';
  player.src=`/audio?id=${sel}&dial=${dial.value}&t=${Date.now()}`;
  try{ await player.play(); status.textContent='playing: '+byId(sel).name; }
  catch(e){ status.textContent='error: '+e; }
};
document.getElementById('analyze').onclick=async()=>{
  status.textContent='analyzing amen.wav…';
  try{
    const r=await fetch('/analyze',{method:'POST'});
    if(!r.ok) throw new Error('server '+r.status);
    const e=await r.json();
    await refresh(); select(e.id);
    status.textContent='added '+e.name+' to My Swing Files';
  }catch(err){ status.textContent='analyze failed: '+err.message; }
};

refresh().then(()=>{ if(data.google[0]) select(data.google[0].id); });
</script>
</body></html>"""


if __name__ == "__main__":
    # PORT is set by the host (Hugging Face Spaces uses 7860); default 5001 local.
    port = int(os.environ.get("PORT", 5001))
    print(f"Groove Player -> http://0.0.0.0:{port}")
    app.run(host="0.0.0.0", port=port, debug=False)
