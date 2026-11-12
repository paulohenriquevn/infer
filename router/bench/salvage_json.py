"""Recovers the complete objects of a truncated JSON array (kubectl cp cut the file)."""
import json, sys
def salvage(path):
    s = open(path).read()
    dec = json.JSONDecoder()
    i = s.index("[") + 1
    out = []
    while True:
        while i < len(s) and s[i] in " \n\r\t,":
            i += 1
        if i >= len(s) or s[i] == "]":
            return out, True
        try:
            obj, i = dec.raw_decode(s, i)
        except json.JSONDecodeError:
            return out, False
        out.append(obj)
if __name__ == "__main__":
    o, ok = salvage(sys.argv[1]); print(len(o), "objects;", "complete file" if ok else "truncated file")
