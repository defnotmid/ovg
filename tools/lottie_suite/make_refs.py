# Renders reference PNGs of a Lottie file with lottie-web in headless
# Chromium, over white at the composition's size:
#
#     python3 make_refs.py lottie.min.js anim.json out_prefix frame...
#
# writes out_prefix_<frame>.png per frame. lottie.min.js comes from the
# lottie-web npm package (build/player/; the suite used 5.12.2).
# LW_RENDERER=canvas picks the canvas renderer (default: svg).
# LW_FONTS="Family=path.ttf;..." embeds fonts (@font-face) and waits for
# them before the animation loads (text layers).
import base64, json, os, subprocess, sys, tempfile
lib, anim, prefix = sys.argv[1], sys.argv[2], sys.argv[3]
frames = sys.argv[4:]
data = json.load(open(anim))
w, h = int(data["w"]), int(data["h"])
js = open(lib).read()
faces, families = "", []
for spec in filter(None, os.environ.get("LW_FONTS", "").split(";")):
    fam, path = spec.split("=", 1)
    faces += "@font-face{font-family:'%s';src:url(data:font/ttf;base64,%s)}" % (fam, base64.b64encode(open(path, "rb").read()).decode())
    families.append(fam)
wait = "Promise.all(%s.map(function(f){return document.fonts.load('16px \\''+f+'\\'')}))" % json.dumps(families)
with tempfile.TemporaryDirectory() as td:
    for fr in frames:
        page = os.path.join(td, "p.html")
        with open(page, "w") as f:
            f.write("<!doctype html><html><head><style>%shtml,body{margin:0;padding:0;background:#fff;overflow:hidden}#a{width:%dpx;height:%dpx}</style></head><body><div id=a></div><script>%s</script><script>%s.then(function(){var anim=lottie.loadAnimation({container:document.getElementById('a'),renderer:'%s',loop:false,autoplay:false,animationData:%s});anim.goToAndStop(%s,true);});</script></body></html>" % (faces, w, h, js, wait, os.environ.get('LW_RENDERER', 'svg'), json.dumps(data), fr))
        out = "%s_%s.png" % (prefix, fr)
        subprocess.run(["timeout", "60", "chromium", "--headless", "--no-sandbox", "--disable-gpu", "--hide-scrollbars", "--force-device-scale-factor=1",
                        "--window-size=%d,%d" % (w, h), "--virtual-time-budget=2000", "--screenshot=" + out, "file://" + page],
                       stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, check=False)
        print(out, os.path.exists(out))
