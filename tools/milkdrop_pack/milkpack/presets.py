"""What a preset's warp/comp shaders reference and sample.

projectM (Renderer/TextureManager.cpp, MilkdropShader::GetReferencedSamplers)
scans the comment-stripped, un-preprocessed shader text for every
`sampler_X` / `texsize_X` and loads each name it finds; a miss binds a 1x1
placeholder. MilkDrop itself only bound what the compiled shader used. So a
texture that is merely declared (template boilerplate such as
`sampler sampler_worms;`) costs nothing when absent, while one the shader
reads renders wrong. `sampled_textures` tells the two apart: it expands
`#define sampler_a sampler_b` aliases and ignores declarations.
"""

import re

# Samplers projectM provides itself (after the XY_ prefix is peeled off).
BUILTIN = {
    "main", "blur1", "blur2", "blur3",
    "noise_lq", "noise_mq", "noise_hq", "noise_lq_lite",
    "noisevol_lq", "noisevol_hq",
}
RAND_RE = re.compile(r"rand\d\d(_.*)?")
TOKEN_RE = re.compile(r"\b(sampler|texsize)_([A-Za-z0-9_]+)")
DEFINE_RE = re.compile(r"#\s*define\s+(sampler_[A-Za-z0-9_]+)\s+(sampler_[A-Za-z0-9_]+)")
DECL_RE = re.compile(
    r"\b(?:uniform\s+)?(?:sampler|sampler2D|sampler3D|texture|float4)\s+"
    r"((?:sampler|texsize)_[A-Za-z0-9_]+)\s*(?=[;:=,)])"
)


def read_milk(data):
    """Parse a .milk file (bytes or str) into {key: value} (the first
    occurrence of a key wins, as in projectM's PresetFileParser)."""
    text = data.decode("latin-1") if isinstance(data, bytes) else data
    values = {}
    for line in text.splitlines():
        key, sep, value = line.partition("=")
        if sep:
            values.setdefault(key.strip().lower(), value)
    return values


def stage_code(values, stage):
    """The warp or comp shader text: stage_1, stage_2, ... until a gap, each
    line's leading backtick removed."""
    lines = []
    i = 1
    while f"{stage}_{i}" in values:
        line = values[f"{stage}_{i}"]
        lines.append(line[1:] if line.startswith("`") else line)
        i += 1
    return "\n".join(lines)


def shader_code(data):
    values = read_milk(data)
    return {s: stage_code(values, s) for s in ("warp", "comp")}


def strip_comments(code):
    code = re.sub(r"/\*.*?\*/", " ", code, flags=re.S)
    return re.sub(r"//[^\n]*", "", code)


def texture_name(token):
    """sampler_fw_clouds -> clouds; sampler_main -> main. Like MilkDrop's
    rule: a 3-char "XY_" prefix is peeled off when more follows."""
    name = token.split("_", 1)[1].lower()
    if len(name) > 3 and name[2] == "_":
        name = name[3:]
    return name


def is_user_texture(name):
    return name not in BUILTIN and name != "state" and not RAND_RE.fullmatch(name)


def referenced_textures(code):
    """Every user texture name projectM would try to load for this code."""
    code = strip_comments(code)
    names = {texture_name(m.group(0)) for m in TOKEN_RE.finditer(code)}
    return {n for n in names if is_user_texture(n)}


def uses_random_texture(code):
    code = strip_comments(code)
    return any(RAND_RE.fullmatch(texture_name(m.group(0))) for m in TOKEN_RE.finditer(code))


def sampled_textures(code):
    """User texture names the shader actually reads (or whose size it uses)."""
    code = strip_comments(code)
    aliases = {}
    for m in DEFINE_RE.finditer(code):
        aliases[m.group(1).lower()] = m.group(2).lower()
    body = DEFINE_RE.sub(" ", code)
    body = DECL_RE.sub(" ", body)
    used = set()
    for m in TOKEN_RE.finditer(body):
        token = m.group(0).lower()
        seen = set()
        while token in aliases and token not in seen:
            seen.add(token)
            token = aliases[token]
        used.add(texture_name(token))
    return {n for n in used if is_user_texture(n)}


def preset_textures(data):
    """(referenced, sampled, uses_rand) over both stages of a preset."""
    referenced, sampled, rand = set(), set(), False
    for code in shader_code(data).values():
        referenced |= referenced_textures(code)
        sampled |= sampled_textures(code)
        rand = rand or uses_random_texture(code)
    return referenced, sampled, rand
