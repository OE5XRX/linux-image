# Spec 0 §7-A: the Opus GStreamer elements (opusenc/opusdec) are the agent's
# bridge codec and the fixture-tone codec. Upstream gst-plugins-base ships the
# opus plugin but leaves it OUT of the default PACKAGECONFIG, so enable it here.
# The elements land in the split package gstreamer1.0-plugins-base-opus, which
# oe5xrx-audio-system pulls into the image.
PACKAGECONFIG:append = " opus"
