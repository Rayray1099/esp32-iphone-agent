"""Fix single-thread FlushFrame reference ownership in pinned OpenH264 2.6.0.

FlushFrame passes NULL to the picture-release helpers, whose fallback picture
buffer is populated only by the threaded decoder. The single-thread decoder
therefore leaks a display reference per flushed picture and exhausts its pool.
Pass its actual context so releasing a quiet AirPlay frame also releases its
display reference. This does not remove the separate H.264 reference ownership.
"""
from pathlib import Path
import sys

path = Path(sys.argv[1]) / "codec/decoder/plus/src/welsDecoderExt.cpp"
text = path.read_text()
before = """  if (bEndOfStreamFlag && m_sReoderingStatus.iNumOfPicts > 0) {
    if (!m_sReoderingStatus.bHasBSlice) {
      ReleaseBufferedReadyPictureNoReorder (NULL, ppDst, pDstInfo);
    }
    else {
      ReleaseBufferedReadyPictureReorder (NULL, ppDst, pDstInfo, true);
    }
  }"""
after = before.replace(
    "    if (!m_sReoderingStatus.bHasBSlice) {",
    "    PWelsDecoderContext flushCtx = m_iThreadCount == 0 ? m_pDecThrCtx[0].pCtx : NULL;\n"
    "    if (!m_sReoderingStatus.bHasBSlice) {",
).replace(" (NULL, ppDst, pDstInfo", " (flushCtx, ppDst, pDstInfo")
if text.count(before) == 1:
    path.write_text(text.replace(before, after))
elif text.count(after) != 1:
    raise SystemExit("Pinned OpenH264 FlushFrame source differs; review patch before building")
print("OpenH264 single-thread flush ownership patch verified")
