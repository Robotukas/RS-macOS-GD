#!/usr/bin/env python3
"""Minimal HID report descriptor decoder: prints items and per-report-ID sizes."""
import sys
MAIN={8:"Input",9:"Output",11:"Feature",10:"Collection",12:"End Collection"}
GLOB={0:"Usage Page",1:"Logical Min",2:"Logical Max",3:"Physical Min",4:"Physical Max",5:"Unit Exponent",6:"Unit",7:"Report Size",8:"Report ID",9:"Report Count",10:"Push",11:"Pop"}
LOC={0:"Usage",1:"Usage Min",2:"Usage Max"}
COLL={0:"Physical",1:"Application",2:"Logical"}
PAGES={1:"Generic Desktop",9:"Button",12:"Consumer"}
GD={0x30:"X",0x31:"Y",0x32:"Z",0x33:"Rx",0x34:"Ry",0x35:"Rz",0x39:"Hat switch",0x04:"Joystick",0x05:"Gamepad"}
def dec(hexs):
    b=bytes.fromhex(hexs); i=0; depth=0; g={}; sizes={}; rid=0
    while i<len(b):
        p=b[i]; sz=[0,1,2,4][p&3]; typ=(p>>2)&3; tag=p>>4; i+=1
        raw=b[i:i+sz]; i+=sz; v=int.from_bytes(raw,'little') if sz else 0
        sv=int.from_bytes(raw,'little',signed=True) if sz else 0
        if typ==0:
            name=MAIN.get(tag,f"Main{tag}")
            if tag==12: depth-=1
            extra=""
            if tag==10: extra=COLL.get(v,str(v))
            elif tag in (8,9,11):
                flags=[]
                flags.append("Const" if v&1 else "Data"); flags.append("Var" if v&2 else "Array"); flags.append("Rel" if v&4 else "Abs")
                if v&64: flags.append("NullState")
                extra=",".join(flags)
                bits=g.get(7,0)*g.get(9,0); sizes.setdefault(rid,{}).setdefault(name,0); sizes[rid][name]+=bits
                extra+=f"  -> {g.get(9,0)}x{g.get(7,0)} bits"
            print("  "*depth+f"{name} ({extra})")
            if tag==10: depth+=1
        elif typ==1:
            name=GLOB.get(tag,f"Glob{tag}"); g[tag]=v
            if tag==8: rid=v
            if tag==0: s=PAGES.get(v,"Vendor" if v>=0xff00 else "")
            elif tag in (1,2,3,4): s=str(sv)
            else: s=""
            print("  "*depth+f"{name} = 0x{v:X} {s}")
        else:
            name=LOC.get(tag,f"Loc{tag}")
            s=GD.get(v,"") if g.get(0)==1 else ""
            print("  "*depth+f"{name} = 0x{v:X} {s}")
    print("Report sizes (bits, excluding report-ID byte):")
    for r,d in sizes.items():
        print(f"  report ID 0x{r:02X}: "+", ".join(f"{k}={v} bits = {v//8}+{v%8} bytes" for k,v in d.items()))
for arg in sys.argv[1:]:
    print(f"===== {arg[:24]}... ====="); dec(arg); print()
