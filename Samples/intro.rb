$c = Catalog.new("Contraptor","components/contraptor","http://www.garagefab.cc/files/kiterpreter/contraptor/")

a6 = Part.new($c, "angle-6")
a6.rotate!([90,0,0]).translate!([0,4,0])

a4 = Part.new($c, "angle-4")
a4.orient!(:left=>:front)
a4[3].above!(a6[0])

asm = Assembly.new("Gadget")
asm << a4
asm << a6

$f = Catalog.new("Fasteners","components/fasteners","http://www.garagefab.cc/files/kiterpreter/fasteners/")

DEFAULT_SCREW = Part::definition($f,"screw-1024-05(ph)")
DEFAULT_NUT = Part::definition($f,"nut-1024(hex)")

fasteners = a6.attach a4, :with=>[ DEFAULT_SCREW, DEFAULT_NUT ]

asm << fasteners

camera = Camera.new("Gadget Assembly")
camera.subject!(asm).shoot 'Assemble the gadget'