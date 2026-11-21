# DaggerSquare Oblique -> TTF สำหรับแอพ: ตัวใหญ่หมด (a-z ใช้รูป A-Z), ขยาย 13%, หนาขึ้นเล็กน้อย (ซ้อนเส้นขอบเลื่อนนิดหน่อย)
from fontTools.ttLib import TTFont, newTable
from fontTools.pens.transformPen import TransformPen
from fontTools.pens.ttGlyphPen import TTGlyphPen
from fontTools.pens.cu2quPen import Cu2QuPen
from fontTools.pens.recordingPen import RecordingPen
import sys
SRC, DST = sys.argv[1], sys.argv[2]
SCALE = 1.13
BOLD = 22          # ความหนาที่เพิ่ม (หน่วยฟอนต์ ก่อนขยาย, em = 1000)
f = TTFont(SRC)
gs = f.getGlyphSet()
order = f.getGlyphOrder()
glyf = newTable('glyf'); glyf.glyphs = {}; glyf.glyphOrder = order
OFFS = [(0, 0), (BOLD, 0), (0, BOLD), (BOLD, BOLD)]
for name in order:
    rec = RecordingPen(); gs[name].draw(rec)
    tt = TTGlyphPen(None)
    if rec.value:
        for dx, dy in OFFS:
            rec.replay(Cu2QuPen(TransformPen(tt, (SCALE, 0, 0, SCALE, dx * SCALE, dy * SCALE)), max_err=1.0, reverse_direction=True))
    glyf.glyphs[name] = tt.glyph()
f['glyf'] = glyf
loca = newTable('loca'); f['loca'] = loca
del f['CFF ']
if 'GPOS' in f: del f['GPOS']
f.sfntVersion = '\x00\x01\x00\x00'
# ความกว้างตัวอักษร + ระยะ
hm = f['hmtx'].metrics
for n, (aw, lsb) in list(hm.items()):
    hm[n] = (int(round((aw + (BOLD if aw else 0)) * SCALE)), int(round(lsb * SCALE)))
for t in f['kern'].kernTables:
    for k in list(t.kernTable): t.kernTable[k] = int(round(t.kernTable[k] * SCALE))
sc = lambda v: int(round(v * SCALE))
hh = f['hhea']; hh.ascent, hh.descent, hh.lineGap = sc(hh.ascent), sc(hh.descent), sc(hh.lineGap)
o = f['OS/2']
o.sTypoAscender, o.sTypoDescender, o.sTypoLineGap = sc(o.sTypoAscender), sc(o.sTypoDescender), sc(o.sTypoLineGap)
o.usWinAscent, o.usWinDescent = sc(o.usWinAscent), sc(o.usWinDescent)
if hasattr(o, 'sxHeight'): o.sxHeight, o.sCapHeight = sc(o.sxHeight), sc(o.sCapHeight)
# maxp เวอร์ชัน TrueType
m = f['maxp']; m.tableVersion = 0x00010000
for a in ('maxZones','maxTwilightPoints','maxStorage','maxFunctionDefs','maxInstructionDefs','maxStackElements','maxSizeOfInstructions'):
    setattr(m, a, {'maxZones': 1}.get(a, 0))
for a in ('maxPoints','maxContours','maxCompositePoints','maxCompositeContours','maxComponentElements','maxComponentDepth'): setattr(m, a, 0)
f['head'].indexToLocFormat = 1
f['head'].glyphDataFormat = 0
f['post'].formatType = 2.0; f['post'].extraNames = []; f['post'].mapping = {}
f['post'].glyphOrder = order
# ตัวพิมพ์เล็ก -> รูปตัวพิมพ์ใหญ่
for t in f['cmap'].tables:
    if not t.isUnicode(): continue
    for c in range(ord('a'), ord('z') + 1):
        up = t.cmap.get(c - 32)
        if up: t.cmap[c] = up
# ชื่อฟอนต์ใหม่ (ไม่ชนตัวเดิม)
for r in f['name'].names:
    if r.nameID in (1, 4): r.string = 'MFB Dagger'
    elif r.nameID == 6: r.string = 'MFBDagger'
f.save(DST)
g = TTFont(DST); g['glyf']; print('ok', len(order), 'glyphs', g['head'].unitsPerEm)
