require 'sketchup.rb'
require 'extensions.rb'
require 'LangHandler.rb'

$uStrings = LanguageHandler.new("Kiterpreter")
ext = SketchupExtension.new $uStrings.GetString("Kiterpreter"), "Kiterpreter/Kiterpreter.rb"                  
ext.description=$uStrings.GetString("Kiterpreter tool for SketchUp.")                        
Sketchup.register_extension ext, true