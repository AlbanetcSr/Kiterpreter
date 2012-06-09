# Kiterpreter - Skethcup plugin to generate kit assembly instructions


require 'sketchup.rb'
include Math

#--------------------------------------------------------------------------

def status(text)
	puts text
	Sketchup::set_status_text
end

#--------------------------------------------------------------------------

def translation_vector(transformation)
	Geom::Vector3d.new(transformation.to_a[12..14])
end

#--------------------------------------------------------------------------

ROUND_TO_DIGITS = 5

class Float
  def round_to(n)
    (self * 10**n).round.to_f / 10**n
  end
end

#--------------------------------------------------------------------------

class Interface
	attr_accessor :origin
	attr_accessor :normal
	attr_accessor :height
	attr_accessor :transformation
	attr_accessor :attached_to

	def initialize(interface)
		return nil unless interface.class == Sketchup::ComponentInstance
		edge = interface.definition.entities[0]
		@transformation = interface.transformation
		
		@origin = edge.line[0].transform(@transformation).to_a.map{|x| x.round_to(ROUND_TO_DIGITS)}
		@origin = Geom::Point3d.new(@origin)		
		
		@normal = edge.line[1].transform(@transformation).to_a.map{|x| x.round_to(ROUND_TO_DIGITS)}
		@normal = Geom::Vector3d.new(@normal)		
		
		@height = edge.length
		@attached_to = nil
	end
	
	# todo: add attached_to interface (array) so it can be "unattached" on part deletion
end

#--------------------------------------------------------------------------

class Cell
	attr_accessor :parent
	attr_accessor :coord
	attr_accessor :world_coord
	
	def initialize(xyz, parent = nil)
		@parent = parent
		# xyz => x,y,z
		x = xyz[0] ? xyz[0] : 0
		y = xyz[1] ? xyz[1] : 0
		z = xyz[2] ? xyz[2] : 0
		if @parent
			entity = @parent.class==Part ? @parent.component : @parent.group 
			vector_add = []
			# multiply entity orientation matrix by desired offsets
			vector_add << @parent.world_transformation.xaxis.to_a.map{|i| i*(x-0)}.map{|i| i.round_to(ROUND_TO_DIGITS)}
			vector_add << @parent.world_transformation.yaxis.to_a.map{|i| i*(y-0)}.map{|i| i.round_to(ROUND_TO_DIGITS)}
			vector_add << @parent.world_transformation.zaxis.to_a.map{|i| i*(z-0)}.map{|i| i.round_to(ROUND_TO_DIGITS)}
			# add offset correction for inverse axes
			vector_add << [-1,0,0] if @parent.world_transformation.inverse.xaxis.to_a.include?(-1)
			vector_add << [0,-1,0] if @parent.world_transformation.inverse.yaxis.to_a.include?(-1)
			vector_add << [0,0,-1] if @parent.world_transformation.inverse.zaxis.to_a.include?(-1)
			# reduce to actual cell offset relative to entity origin
			vector_add = vector_add.inject{|sum,i| [sum[0]+i[0], sum[1]+i[1], sum[2]+i[2]]}
			# store offsets in parent and world coordinates
			@local_coord = Geom::Vector3d.new(vector_add.map{|i| i.round_to(ROUND_TO_DIGITS)})
			@coord = Geom::Vector3d.new(entity.transformation.origin.to_a) + @local_coord
			@world_coord = Geom::Vector3d.new(@parent.world_transformation.to_a[12..14]) + @local_coord
		else
			# world cell
			@coord = Geom::Vector3d.new([x,y,z])
			@world_coord = Geom::Vector3d.new([x,y,z])
		end
		self
	end
	
	def occupy!(cell)
		return nil unless @parent	# nothign to occupy with
		cell = Cell.new(cell) if cell.class == Array	# to allow something like angle[3].occupy!([0,0,0])
#		translation = (cell.coord - @coord).to_a
		translation = (cell.world_coord - @world_coord).to_a
		translation.map!{|i| i.round_to(ROUND_TO_DIGITS)}
		@parent.translate!(Geom::Vector3d.new(translation))
	end
	
	def to_right!(cell)
		occupy!(cell)
		@parent.x!(1)
	end
	def to_left!(cell)
		occupy!(cell)
		@parent.x!(-1)
	end
	def behind!(cell)
		occupy!(cell)
		@parent.y!(1)
	end
	def in_front!(cell)
		occupy!(cell)
		@parent.y!(-1)
	end
	def above!(cell)
		occupy!(cell)
		@parent.z!(1)
	end
	def below!(cell)
		occupy!(cell)
		@parent.z!(-1)
	end
end

#--------------------------------------------------------------------------

class Part
	attr_accessor :name
	attr_accessor :catalog
	attr_accessor :interfaces
	attr_accessor :parent
	attr_accessor :component
	attr_accessor :world_transformation
	
	def self.definition(catalog, name)
		{:catalog=>catalog, :name=>name}
	end
	
	def self.instances_each
		ObjectSpace.each_object(Part) {|p| yield p}
	end
	
	def initialize(catalog, name)
		@catalog, @name = catalog, name
		@catalog.download_part(@name) unless @catalog.part_available?(@name)
		@catalog.part_available?(@name) or raise "Part '#{@catalog.name}::#{@name}' could not be loaded" 
		
		definition = Sketchup.active_model.definitions.load @catalog.path_to(@name)
		definition.name = @catalog.name + "::" + @name
		@component = Sketchup.active_model.entities.add_instance definition, Geom::Transformation.new
		@parent = nil
		@deleted = false
		@world_transformation = Geom::Transformation.new
		@interfaces = []
		@component.definition.entities.each {|e| @interfaces << Interface.new(e) if e.layer.name == "interface"}
		status "Part '#{@catalog.name}::#{@name}' created"				
		self
	end

	def translate!(xyz=[0,0,0])
		transformation = Geom::Transformation.new(xyz)
		transformation = @parent.world_transformation * transformation * @parent.world_transformation.inverse if @parent
		@component.transform! transformation
		@world_transformation = transformation*@world_transformation
		status "Part '#{@catalog.name}::#{@name}' translated: #{xyz.to_a.join(",")}"
		self
	end
	
	def origin!(xyz=[0,0,0])
		self.translate!(Geom::Vector3d.new(xyz) - Geom::Vector3d.new(@component.transformation.origin.to_a))
	end
	
	def x!(x=0) translate!([x,0,0]) end
	def y!(y=0) translate!([0,y,0]) end
	def z!(z=0) translate!([0,0,z]) end

	def rotate!(xyz=[0,0,0], center = false)
		# todo: rewrite to use global axes for rotation when in parent group
		
		point = center ? @component.bounds.center : @component.transformation.origin
		status "Rotating around point: #{point}"
		transformation = Geom::Transformation.rotation(point, [1,0,0], xyz[0]*PI/180)
		@component.transform!(transformation)
		@world_transformation = transformation*@world_transformation
		
		point = center ? @component.bounds.center : @component.transformation.origin
		status "Rotating around point: #{point}"		
		transformation = Geom::Transformation.rotation(point, [0,1,0], xyz[1]*PI/180)
		@component.transform!(transformation)
		@world_transformation = transformation*@world_transformation
		
		point = center ? @component.bounds.center : @component.transformation.origin
		status "Rotating around point: #{point}"		
		transformation = Geom::Transformation.rotation(point, [0,0,1], xyz[2]*PI/180)
		@component.transform!(transformation)
		@world_transformation = transformation*@world_transformation
		
		status "Part '#{@catalog.name}::#{@name}' rotated: #{xyz.to_a.join(",")}"
		self
	end
	
	def orient!(rotations)
		# rotations supplied as side=>direction hash: orient!(:top=>:right, :back=>:left)
		constraints = []
		
		directions = {:left=>[-1,0,0], :right=>[1,0,0], :front=>[0,-1,0], :back=>[0,1,0], :down=>[0,0,-1], :up=>[0,0,1]}
		directions.update :lt=>[-1,0,0], :rt=>[1,0,0], :fr=>[0,-1,0], :bk=>[0,1,0], :dn=>[0,0,-1], :up=>[0,0,1]
		directions.update "left"=>[-1,0,0], "right"=>[1,0,0], "front"=>[0,-1,0], "back"=>[0,1,0], "down"=>[0,0,-1], "up"=>[0,0,1]
		directions.update "lt"=>[-1,0,0], "rt"=>[1,0,0], "fr"=>[0,-1,0], "bk"=>[0,1,0], "dn"=>[0,0,-1], "up"=>[0,0,1]
		
		rotations.each do |side,direction|
			around_vector = nil
			case side
			when :left,:lt
				from_vector = @component.transformation.xaxis.reverse
			when :right,:rt
				from_vector = @component.transformation.xaxis
			when :front,:fr
				from_vector = @component.transformation.yaxis.reverse
			when :back,:bk,:rear,:re,:rr
				from_vector = @component.transformation.yaxis
			when :bottom,:bm,:bt,:dn
				from_vector = @component.transformation.zaxis.reverse
			when :top,:tp,:up
				from_vector = @component.transformation.zaxis
			end

			to_vector = Geom::Vector3d.new(directions[direction])			
			
			case from_vector.angle_between(to_vector).round_to(ROUND_TO_DIGITS).abs			
			when 0	# no rotation necessary
				constraints << to_vector.to_a.map{|i| i.round_to(ROUND_TO_DIGITS)}				
			when (PI/2).round_to(ROUND_TO_DIGITS)	# 90 degrees
				next if constraints.uniq.length > 1	# can't rotate when constrained on 2 axes
				around_vector = from_vector * to_vector
				if constraints.uniq.length==1
					around_vector = nil unless around_vector.parallel?(Geom::Vector3d.new(constraints.uniq[0]))
				end
				if around_vector
					around_vector.length = 90	# hack [1,0,0] => [90,0,0]
					self.rotate!(around_vector.to_a.map{|i| i.round_to(ROUND_TO_DIGITS)}, center = true)
					constraints << to_vector.to_a.map{|i| i.round_to(ROUND_TO_DIGITS)}
				end				
			when PI.round_to(ROUND_TO_DIGITS)	# 180 degrees
				next if constraints.uniq.length > 1	# can't rotate when constrained on 2 axes
				around_vector = from_vector.axes[0]	if constraints.uniq.empty?	# rotate around arbitrary axis perpendicular to from_vector (and to_vector)
				around_vector = Geom::Vector3d.new(constraints.uniq[0]) if constraints.uniq.length==1	# or rotate around the constrained axis, if exists
				around_vector = nil if around_vector.parallel?(from_vector)	# ...as long as constrained axis is not parallel to from_vector (and to_vector)
				if around_vector
					around_vector.length = 180	# hack [1,0,0] => [180,0,0]
					self.rotate!(around_vector.to_a.map{|i| i.round_to(ROUND_TO_DIGITS)}, center = true)
					constraints << to_vector.to_a.map{|i| i.round_to(ROUND_TO_DIGITS)}					
				end
			end			
		end
		self
	end

	def [](*args)
		Cell.new(args,self)
	end
	
	def occupy!(cell)
		self[0].occupy!(cell)
	end
	
	def delete!
		@parent.remove(self) unless @parent.nil?
		Sketchup.active_model.entities.erase_entities(@component)
		@deleted = true
		status "Part '#{@catalog.name}::#{@name}' deleted"
	end
	
	def deleted?
		@deleted
	end
	
	def layer
		@component.layer
	end

	def layer=(layer)
		@component.layer = layer
	end
	
	def show
		begin
			@component.hidden = false
			status "Part '#{@name}' visible"
		rescue
			puts "exception while showing part: #{@name}, id: #{self}, parent: #{@parent}"
		end
		self
	end
	
	def hide
		begin 
			@component.hidden = true
			status "Part '#{@name}' hidden"
		rescue
			puts "exception while hiding part: #{@name}, id: #{self}, parent: #{@parent}"
		end
		self
	end
	
	def can_attach?(part)
		# must be redefined by assembly script
		false
	end
	
	def attach(something, options={})
		return attach_part(something, options) if something.class == Part
		return attach_assembly(something, options) if something.class == Assembly
	end
	
	def attach_part(part, options={})
		a,b = self,part
		options = {:pattern=>"1"}.merge(options)
		out = []
		
		common_normals = []	
		a.interface_normals.each do |an|
			b.interface_normals.each do |bn|
				common_normals << { :a=>an, :b=>bn } if an.reverse == bn
			end
		end
		common_normals.each do |n|
			common_interfaces = []	
			a.interfaces_by_normal(n[:a]).each do |ai|
				b.interfaces_by_normal(n[:b]).each do |bi|
					common_interfaces << { :a=>ai, :b=>bi } if ai.origin.transform(a.world_transformation) == bi.origin.transform(b.world_transformation)
				end
			end

			o = Geom::Point3d.new(0,0,0)
			common_interfaces.sort! {|m,n| m[:a].origin.distance(o) <=> n[:a].origin.distance(o)}			
			pattern = options[:pattern].scan(/./)		# "010" -> ["0","1","0"]
			common_interfaces.each do |interface_pair|

				index = common_interfaces.index(interface_pair)
				next if pattern[index.modulo(pattern.size)] == "0" # || pattern[index.modulo(pattern_array.size)] == "-"
				fasteners = options[:with]
				if fasteners.nil?
					# fasteners are not supplied directly - skip if cannot attach or get_fasteners callback is not defined; otherwise get fasteners
					next unless a.can_attach?(b) && a.respond_to?("get_fasteners")
					fasteners = a.get_fasteners(b)
				end
				# i can haz fasteners - coerce things at 0 and 1 into a and b side arrays. can't use splat as it will convert single Hash to Array, while we need Array of Hashes
				a_side = fasteners[0].class==Array ? fasteners[0] : [fasteners[0]]
				b_side = fasteners[1].class==Array ? fasteners[1] : [fasteners[1]]
				raise "Fasteners must be supplied as Part::definition()" if (a_side+b_side).map{|i| i.class}.uniq != [Hash]
				
				offset = interface_pair[:a].height
				unless interface_pair[:a].attached_to
					a_side.reverse_each do |f|
	#					next if interface_pair[:a].attached_to 	# be careful here with [] from 2D interface (future)
						fastener = Part.new(f[:catalog], f[:name]) or raise "Invalid fastener :catalog=>#{f[:catalog]}, :part=>#{f[:name]}"
						transformation = a.world_transformation * interface_pair[:a].transformation * Geom::Transformation.new([0,0,offset])
						fastener.component.transformation = fastener.world_transformation = transformation
						offset += fastener.interfaces[0].height if fastener.interfaces[0]	# workaround - currently screws dont't have interfaces (shoud they?)
						interface_pair[:a].attached_to = interface_pair[:b]
						out << fastener
					end
				end

				offset = interface_pair[:b].height
				unless interface_pair[:b].attached_to
					b_side.each do |f|
	#					next if interface_pair[:b].attached_to 	# be careful here with [] from 2D interface (future)
						fastener = Part.new(f[:catalog], f[:name]) or raise "Invalid fastener :catalog=> , :part=> "
						transformation = b.world_transformation * interface_pair[:b].transformation * Geom::Transformation.new([0,0,offset])
						fastener.component.transformation = fastener.world_transformation = transformation
						offset += fastener.interfaces[0].height if fastener.interfaces[0]	# workaround - currently screws dont't have interfaces (shoud they?)
						interface_pair[:b].attached_to = interface_pair[:a]
						out << fastener
					end
				end
			end
		end
		out
	end
	
	def attach_assembly(assembly, options={})
		out = []
		assembly_children = assembly.children.clone
		assembly_children.each {|c| out << self.attach(c,options)}
		out.flatten
	end
	
	def interface_normals()
		interface_normals = []				
		@interfaces.each {|i| interface_normals << i.normal.transform(@world_transformation).to_a}
		interface_normals.uniq.map {|xyz| Geom::Vector3d.new(xyz)}
	end
	
	def interfaces_by_normal(normal)
		interfaces_by_normal = []
		@interfaces.each {|i| interfaces_by_normal << i if i.normal.transform(@world_transformation) == normal}
		interfaces_by_normal
	end

end

#--------------------------------------------------------------------------

class Assembly
	attr_accessor :name
	attr_accessor :children
	attr_accessor :parent
	attr_accessor :group
	attr_accessor :world_transformation
	attr_accessor :named_children
	
	def self.instances_each	
		ObjectSpace.each_object(Assembly) {|a| yield a}
	end

	def initialize(name)
		@group = Sketchup.active_model.entities.add_group
		@group.name = @name = name
		@children = []
		@named_children = {}
		@parent = nil
		@deleted = false
		@world_transformation = Geom::Transformation.new		
		status "Assembly '#{@name}' created"
		self
	end
	
	def translate!(xyz=[0,0,0])
		transformation = Geom::Transformation.new(xyz)
		transformation = @parent.world_transformation * transformation * @parent.world_transformation.inverse if @parent
		@group.transform! transformation
		@world_transformation = transformation*@world_transformation
		propagate_transformation(transformation)
		status "Assembly '#{@name}' translated: #{xyz.to_a.join(",")}"
		self
	end

	def origin!(xyz=[0,0,0])
		self.translate!(Geom::Vector3d.new(xyz) - Geom::Vector3d.new(@group.transformation.origin.to_a))
	end
	
	def x!(x=0) translate!([x,0,0]) end
	def y!(y=0) translate!([0,y,0]) end
	def z!(z=0) translate!([0,0,z]) end

	def rotate!(xyz=[0,0,0], center = false)
		# todo: rewrite to use global axes when in parent group
	
		point = center ? @group.bounds.center : @group.transformation.origin
		transformation = Geom::Transformation.rotation(point, [1,0,0], xyz[0]*PI/180)
		@group.transform!(transformation)
		@world_transformation = transformation*@world_transformation
		propagate_transformation(transformation)
		
		point = center ? @group.bounds.center : @group.transformation.origin
		transformation = Geom::Transformation.rotation(point, [0,1,0], xyz[1]*PI/180)
		@group.transform!(transformation)
		@world_transformation = transformation*@world_transformation
		propagate_transformation(transformation)
		
		point = center ? @group.bounds.center : @group.transformation.origin
		transformation = Geom::Transformation.rotation(point, [0,0,1], xyz[2]*PI/180)
		@group.transform!(transformation)
		@world_transformation = transformation*@world_transformation
		propagate_transformation(transformation)
		
		status "Assembly '#{@name}' rotated: #{xyz.to_a.join(",")}"
		self
	end

	def orient!(rotations)
		# rotations supplied as hash: orient!(:top=>:right, :back=>:left)
		constraints = []
		directions = {:left=>[-1,0,0], :right=>[1,0,0], :front=>[0,-1,0], :back=>[0,1,0], :down=>[0,0,-1], :up=>[0,0,1]}
		rotations.each do |side,direction|
			around_vector = nil
			case side
			when :left
				from_vector = @group.transformation.xaxis.reverse
			when :right
				from_vector = @group.transformation.xaxis
			when :front
				from_vector = @group.transformation.yaxis.reverse
			when :back
				from_vector = @group.transformation.yaxis
			when :bottom
				from_vector = @group.transformation.zaxis.reverse
			when :top
				from_vector = @group.transformation.zaxis
			end

			to_vector = Geom::Vector3d.new(directions[direction])			
			
			case from_vector.angle_between(to_vector).round_to(ROUND_TO_DIGITS).abs			
			when 0	# no rotation necessary
				constraints << to_vector.to_a.map{|i| i.round_to(ROUND_TO_DIGITS)}				
			when (PI/2).round_to(ROUND_TO_DIGITS)	# 90 degrees
				next if constraints.uniq.length > 1	# can't rotate when constrained on 2 axes
				around_vector = from_vector * to_vector
				if constraints.uniq.length==1
					around_vector = nil unless around_vector.parallel?(Geom::Vector3d.new(constraints.uniq[0]))
				end
				if around_vector
					around_vector.length = 90
					self.rotate!(around_vector.to_a.map{|i| i.round_to(ROUND_TO_DIGITS)}, center = true)
					constraints << to_vector.to_a.map{|i| i.round_to(ROUND_TO_DIGITS)}
				end				
			when PI.round_to(ROUND_TO_DIGITS)	# 180 degrees
				next if constraints.uniq.length > 1	# can't rotate when constrained on 2 axes
				around_vector = from_vector.axes[0]	if constraints.uniq.empty?	# rotate around arbitrary axis perpendicular to from_vector (and to_vector)
				around_vector = Geom::Vector3d.new(constraints.uniq[0]) if constraints.uniq.length==1	# rotate around the constrained axis
				around_vector = nil if around_vector.parallel?(from_vector)	# as long as constrained axis is not parallel to from_vector (and to_vector)
				if around_vector
					around_vector.length = 180
					self.rotate!(around_vector.to_a.map{|i| i.round_to(ROUND_TO_DIGITS)}, center = true)
					constraints << to_vector.to_a.map{|i| i.round_to(ROUND_TO_DIGITS)}					
				end
			end			
		end
		self
	end

	def [](*args)
		Cell.new(args,self)
	end
	
	def occupy!(cell)
		self[0].occupy!(cell)
	end
		
	def delete!
		@parent.remove(self) unless @parent.nil?
		children = @children.clone	# must clone as deletion of children affects @children array, messing with the iterator
		children.each {|c| c.delete!}
		Sketchup.active_model.entities.erase_entities(@group)
		@deleted = true
		status "Assembly '#{@name}' deleted"				
	end
	
	def deleted?
		@deleted
	end
	
	def layers
		layers = []
		@children.each {|c| layers << c.layer}
		layers.uniq
	end

	def layer=(layer)
		@children.each {|c| c.layer = layer}
	end
	
	def show
		begin
			@group.hidden = false
			status "Assembly '#{@name}' visible"
		rescue
			puts "exception while showing assembly: #{@name}, id: #{self}, parent: #{@parent}"
		end
		self
	end
	
	def hide
		begin
			@group.hidden = true
			status "Assembly '#{@name}' hidden"
		rescue
			puts "exception while hiding assembly: #{@name}, id: #{self}, parent: #{@parent}"
		end
		self
	end
	
	def propagate_transformation(transformation)
		@children.each do |c|
			c.world_transformation = transformation*c.world_transformation
			c.propagate_transformation(transformation) if c.class == Assembly
		end
	end
	
	def <<(something)
		add(something)
	end
	
	def add(something)
		something.each{|s| add(s)} if something.class == Array
		add_part(something) if something.class == Part
		add_assembly(something) if something.class == Assembly
		self
	end
	
	def add_part(part)
		part.parent.nil? or raise "Part '#{part.catalog.name}::#{part.name}' already added to assembly '#{part.parent.name}'"
		cloned_component = @group.entities.add_instance part.component.definition, @world_transformation.inverse*part.component.transformation
		cloned_component.layer = part.component.layer
		Sketchup.active_model.entities.erase_entities part.component
		part.component = cloned_component
		status "Part '#{part.catalog.name}::#{part.name}' added to assembly '#{@name}'"
		@children << part
		part.parent = self
		self
	end
	
	def add_assembly(assembly)
		assembly.parent.nil? or raise "Assembly '#{assembly.name}' already added to assembly '#{assembly.parent.name}'"
		
		cloned_group = @group.entities.add_group
		cloned_group.name = assembly.group.name
		cloned_group.transformation = @world_transformation.inverse*assembly.group.transformation
		
		original_children = assembly.children.clone
		original_children.each {|c| assembly.remove(c)}
		@group.entities.erase_entities assembly.group
		
		assembly.group = cloned_group
		original_children.each {|c| assembly.add(c)}
		
		status "Assembly '#{assembly.name}' added to assembly '#{@name}'"
		@children << assembly
		assembly.parent = self
		self
	end
	
	def remove(something)
		something.each{|s| remove(s)} if something.class == Array
		remove_part(something) if something.class == Part
		remove_assembly(something) if something.class == Assembly
		self
	end
	
	def remove_part(part)
		@children.include?(part) or raise "Part '#{part.catalog.name}: #{part.name}' is not in assembly '#{@name}'"		

		cloned_component = Sketchup.active_model.entities.add_instance part.component.definition, part.world_transformation
		cloned_component.layer = part.component.layer
		
		@group.entities.erase_entities part.component
		part.component = cloned_component
		
		status "Part '#{part.catalog.name}: #{part.name}' removed from assembly '#{@name}'"
		@children.delete(part)
		part.parent = nil
		self
	end
	
	def remove_assembly(assembly)
		@children.include?(assembly) or raise "Assembly '#{assembly.name}' is not in assembly '#{@name}'"
		
		cloned_group = Sketchup.active_model.entities.add_group
		cloned_group.name = assembly.group.name
		cloned_group.transformation = assembly.world_transformation
		
		original_children = assembly.children.clone
		original_children.each {|c| assembly.remove(c)}
		@group.entities.erase_entities assembly.group
		
		assembly.group = cloned_group
		original_children.each {|c| assembly.add(c)}
		
		status "Assembly '#{assembly.name}' removed from assembly '#{@name}'"
		@children.delete(assembly)
		assembly.parent = nil
		self
	end
	
	def attach(something=self, options={})
		return attach_part(something, options) if something.class == Part
		out = attach_assembly(something, options) if something.class == Assembly
		return self.add(out) if something==self
		out
	end

	def attach_part(part, options={})
		out = []
		children = @children.clone
		children.each {|c| out << c.attach(part,options)}
		out.flatten
	end
	
	def attach_assembly(assembly, options={})
		out = []
		children = @children.clone
		children.each {|c| out << c.attach(assembly,options)}
		out.flatten
	end
	
	def bom(options={})
	end
	
end

#--------------------------------------------------------------------------

class DefinitionLoadHandler
	attr_accessor :error

	def onPercentChange(p)
		Sketchup::set_status_text("LOADING: " + p.to_i.to_s + "%")
	end

	def cancelled?
		# You could, for example, show a messagebox after X seconds asking if the
		# user wants to cancel the download. If this method returns true, then
		# the download cancels.
		return false
	end

	def onSuccess
		Sketchup::set_status_text('')
		@error = nil
	end

	def onFailure(error_message)
		# A real implementation would probably not use a global variable,
		# but this demonstrates storing any error we receive.
		Sketchup::set_status_text('')
		@error = error_message
	end

end

#--------------------------------------------------------------------------

class Catalog
	attr_accessor :name
	
	def self.find(name)
		ObjectSpace.each_object(Catalog) {|c| return c if c.name==name}
	end	

	def initialize(name, path, url=nil)
		#remove trailing slash from path and url
		@name, @path, = name, /(.*)(\/?)$/.match(path)[0]
		@url = url.nil? ? nil : /(.*)(\/?)$/.match(url)[0]
		
		#look up magic file to get Sketchup app dir (not tested on Mac)
		@sketchup_dir = /(.*)(\/Components\/Components Sampler\/bed.skp)$/.match(Sketchup.find_support_file("bed.skp", "Components/Components Sampler"))[1]
		@load_handler = DefinitionLoadHandler.new
	end
	
	def path_to(part)
		@sketchup_dir + "/" + @path + "/" + part + ".skp"
	end
	
	def part_available?(part)
		File.exists?(path_to(part))
	end
	
	def download_part(part)
		return nil if url.nil?
		
		Dir.chdir(@sketchup_dir)
		Dir.mkdir(@path) unless File.directory?(@path)

		#load definition from url
		Sketchup.active_model.definitions.load_from_url(@url + "/" + part + ".skp", @load_handler)
		if @load_handler.error
			status("Error: " + @load_handler.error.to_s + " for part " + @url + "/" + part + ".skp")
			return nil
		end
		definition = Sketchup.active_model.definitions[Sketchup.active_model.definitions.count - 1]
		definition.name = "temporary_definition"

		#save definition to path and purge it from model
		definition.save_as(path_to(part)) or raise "Could not save #{path_to(part)}"
		Sketchup.active_model.definitions.purge_unused
	end
end

#--------------------------------------------------------------------------

class Camera
	attr_accessor :name
	attr_accessor :camera
	
	def self.set_defaults(defaults)
		@@defaults = Hash.new unless defined? @@defaults
		@@defaults.update(defaults)
	end
	
	def initialize(name, options={})
		defaults = {:can_shoot=>false,:global_sequence_no=>0,:eye=>[100,-100,100],:target=>[0,0,0],:up=>[0,0,1],:perspective=>true,:image_width=>720,:image_height=>480}
		@@defaults = Hash.new unless defined? @@defaults
		defaults.each {|key,value| @@defaults[key] ||= value}
		
		@name, @subject = name, nil
		@defaults = @@defaults.merge(options)
		
		@camera = Sketchup::Camera.new(@defaults[:eye], @defaults[:target], @defaults[:up])
		@camera.perspective = @defaults[:perspective]
	end
	
	def set!(orientation)
		orientation = {:eye=>@camera.eye, :target=>[0,0,0], :up=>[0,0,1]}.merge(orientation)
		@camera.set(orientation[:eye], orientation[:target], orientation[:up])
		self
	end
	
	def perspective(true_or_false)
		@camera.perspective = true_or_false
		self
	end
	
	def subject!(subject=nil)
		raise "Camera subject must be either Part, Assembly or nil" unless [NilClass,Part,Assembly].include?(subject.class)
		@subject = subject
		self
	end
	
	def shoot(description=nil)
		return unless @@defaults[:can_shoot]

		# generate screenshot file name
		@@defaults[:global_sequence_no] += 1
		file_name = "%03d" % @@defaults[:global_sequence_no]
		file_name = "#{file_name}-#{@subject.name.gsub(' ','-')}" unless @subject.nil?
		
		Sketchup.active_model.active_view.camera = @camera
		if @subject.nil?
			view = Sketchup.active_model.active_view.zoom_extents
			view.write_image(File.join(@@defaults[:image_path],"#{file_name}.png"), @@defaults[:image_width], @@defaults[:image_height], true)
			status "Screenshot #{file_name} taken"
		else
			Assembly::instances_each { |a| a.hide unless a.parent || a.deleted? }
			Part::instances_each { |p| p.hide unless p.parent || p.deleted? }
			
			@subject.show #if @subject.class == Assembly || (@subject.class == Part && @subject.parent.nil?)
			parent = @subject.parent
			while parent
				parent.show
				parent = parent.parent
			end

			view = Sketchup.active_model.active_view
			original_eye = view.camera.eye	# this is used later, see below
			original_up = view.camera.up
			target_entity = @subject.class==Assembly ? @subject.group : @subject.component
			
			view.zoom target_entity
			# the following workaround is needed because view.zoom does not take into account the transformation of the parent group (a bug?)
			if @subject.parent
				eye = view.camera.eye.transform(@subject.parent.world_transformation)
				target = view.camera.target.transform(@subject.parent.world_transformation)
				up = original_up

				# now we're zoomed into desired subject but not from the desired angle
				# the following moves the camera eye to the desired angle while preseving zoom
				eye_target_distance = (target - eye).length
				
				# assume center of the entity bounding box as a target
				target = target_entity.bounds.center.transform(@subject.parent.world_transformation)
				target_to_cam_vector = original_eye - target
				target_to_cam_vector.length = eye_target_distance
				eye = target + target_to_cam_vector
				
				# finally set camera
				view.camera.set(eye, target, up)
			end			
			view.write_image(File.join(@@defaults[:image_path],"#{file_name}.png"), @@defaults[:image_width], @@defaults[:image_height], true)

			status "Screenshot #{file_name} taken, subject: #{@subject.name}"
			view.invalidate

			Assembly::instances_each {|a| a.show unless a.deleted?}
			Part::instances_each {|p| p.show unless p.deleted?}
		end
		Sketchup.active_model.active_view.refresh
		File.open(File.join(@@defaults[:image_path], "#{file_name}.txt"), "w") {|f| f.puts description} if description
		File.open(File.join(@@defaults[:image_path], @@defaults[:step_file]), "a+") {|f| f.puts file_name}
		
		# revert to default perspective
		@camera.perspective = @defaults[:perspective]
	end
end

#--------------------------------------------------------------------------

class Kiterpreter
	
	def initialize()
	end

	def add_tools(toolbar)
	
		tools = []
		tools << {:text=>"Load Kiterpeter script", :function=>Proc.new{self.button_load_file}, :icon=>"load_file.png"}
		tools << {:text=>"Reload Kiterpeter script", :function=>Proc.new{self.button_reload_file}, :icon=>"reload_file.png"}
		tools << {:text=>"Reload Kiterpeter script and output instructions", :function=>Proc.new{self.button_reload_file_save_screenshots}, :icon=>"save_shots.png"}
		tools << {:text=>"Dump code to console", :function=>Proc.new{self.button_dump_code_to_console}, :icon=>"dump_code.png"}
		
		tools.each do |t|			
			cmd = UI::Command.new(t[:text]) { t[:function].call }
			path = Sketchup.find_support_file t[:icon], "plugins/Kiterpreter/Images/"	
			cmd.small_icon = cmd.large_icon = path
			cmd.tooltip = cmd.status_bar_text = cmd.menu_text = t[:text]
			toolbar = toolbar.add_item cmd
		end
	end
	
	def button_load_file()
		@assembly_file = UI.openpanel("Load Kiterpreter assembly file", "", "*.rb") and load @assembly_file
		Sketchup.active_model.definitions.purge_unused
		status "Done"
	end
	
	def button_reload_file()
		return unless @assembly_file
		if Sketchup.active_model.active_entities.count > 0
			result = UI::messagebox "Delete existing entities?", MB_YESNOCANCEL
			return if result == 2 #Cancel
			Sketchup.active_model.active_entities.clear! if result == 6 #Yes
		end
		ObjectSpace.garbage_collect
		load @assembly_file	
		status "Done"
	end

	def button_reload_file_save_screenshots()
		return unless @assembly_file
		if Sketchup.active_model.active_entities.count > 0
			result = UI::messagebox("Existing entities will be deleted. Proceed?", MB_OKCANCEL)
			return unless result == 1 #OK
			Sketchup.active_model.active_entities.clear!
		end
		screenshot_path = UI.savepanel("Save screenshots to", "" ,"screenshot.png") and screenshot_path = File::dirname(screenshot_path)
		return unless screenshot_path		
		
		ObjectSpace.garbage_collect
		
		step_file = "@steps.txt"
		File.delete(File.join(screenshot_path,step_file)) if File.exists?(File.join(screenshot_path,step_file))
		Camera::set_defaults(:global_sequence_no=>0, :image_path=>screenshot_path, :can_shoot=>true, :step_file=>step_file)
		load @assembly_file
		Camera::set_defaults(:can_shoot=>false)
		
		# generate HTML - this is clumsy and needs to be rewritten
		steps = IO.readlines(File.join(screenshot_path,step_file))
		f_doc = File.open(File.join(screenshot_path,"@doc.html"),"w")
		f_doc.puts "<html><body>"
		steps.each do |s|
			f_doc.puts "<div>"
			f_doc.puts "<img src='#{s.strip}.png' style='float:left; margin:0 10px 0 0;'/>"
			f_doc.puts "<h3>#{s.strip}</h3>"
			if File.exist?(File.join(screenshot_path,"#{s.strip}.txt"))
				File.open(File.join(screenshot_path,"#{s.strip}.txt"),"r") do |f_step|
					f_step.each_line { |l| f_doc << "<p>#{l[0..6].upcase == "HTTP://" ? "<a href='#{l.strip}'>#{l.strip}</a>" : l.strip}</p>" }
				end
			end
			f_doc.puts "</div>"
			f_doc.puts "<hr style='page-break-after:always; clear:left;'>"
		end
		f_doc.puts "</body></html>"
		f_doc.close
		
		status "Done"
	end
	
	def button_dump_code_to_console()
	
		# this function needs a complete rewrite
	
		world_X = Geom::Vector3d.new 1.0, 0.0, 0.0
		world_Y = Geom::Vector3d.new 0.0, 1.0, 0.0
		world_Z = Geom::Vector3d.new 0.0, 0.0, 1.0

		rotation_map = Hash.new()
		rotation_map["X+Y+Z+"] = [0,0,0]
		rotation_map["Y-X+Z+"] = [0,0,90]
		rotation_map["Y+X-Z+"] = [0,0,-90]
		rotation_map["X-Y-Z+"] = [0,0,180]
		rotation_map["X-Y+Z-"] = [0,180,0]
		rotation_map["Y-X-Z-"] = [0,180,90]
		rotation_map["Y+X+Z-"] = [0,180,-90]
		rotation_map["X+Y-Z-"] = [0,180,180]
		rotation_map["Z+Y+X-"] = [0,90,0]
		rotation_map["Y-Z+X-"] = [0,90,90]
		rotation_map["Y+Z-X-"] = [0,90,-90]
		rotation_map["Z-Y-X-"] = [0,90,180]
		rotation_map["Z-Y+X+"] = [0,-90,0]
		rotation_map["Y-Z-X+"] = [0,-90,90]
		rotation_map["Y+Z+X+"] = [0,-90,-90]
		rotation_map["Z+Y-X+"] = [0,-90,180]
		rotation_map["X+Z-Y+"] = [90,0,0]
		rotation_map["Z+X+Y+"] = [90,0,90]
		rotation_map["Z-X-Y+"] = [90,0,-90]
		rotation_map["X-Z+Y+"] = [90,0,180]
		rotation_map["X+Z+Y-"] = [-90,0,0]
		rotation_map["Z-X+Y-"] = [-90,0,90]
		rotation_map["Z+X-Y-"] = [-90,0,-90]
		rotation_map["X-Z-Y-"] = [-90,0,180]

		puts "# -----------------------------------------------"
		dump_camera_coordinates if Sketchup.active_model.selection.empty?
		Sketchup.active_model.selection.each do |entity|
			
			next unless entity.class == Sketchup::ComponentInstance or entity.class == Sketchup::Group
			
			if entity.class == Sketchup::ComponentInstance then
				catalog = /^([^ #:]*)(::)([^ #:]*)(#*)([0-1]*)$/.match(entity.definition.name)[1]
				part = /^([^ #:]*)(::)([^ #:]*)(#*)([0-1]*)$/.match(entity.definition.name)[3]
				output_string = "Part.new(Catalog::find(\"#{catalog}\"), \"#{part}\")"
			elsif entity.class == Sketchup::Group then
				output_string = "Assembly.new(\"#{entity.name}\")"
			end

			entity_axes = Hash.new()
			entity_axes["X+"] = entity.transformation.xaxis
			entity_axes["X-"] = entity.transformation.xaxis.reverse
			entity_axes["Y+"] = entity.transformation.yaxis
			entity_axes["Y-"] = entity.transformation.yaxis.reverse
			entity_axes["Z+"] = entity.transformation.zaxis
			entity_axes["Z-"] = entity.transformation.zaxis.reverse
			
			orientation_key = ""

			entity_axes.each_key { |key| orientation_key = orientation_key + key if entity_axes[key] == world_X }
			entity_axes.each_key { |key| orientation_key = orientation_key + key if entity_axes[key] == world_Y }
			entity_axes.each_key { |key| orientation_key = orientation_key + key if entity_axes[key] == world_Z }

			output_string = output_string + ".rotate!([#{rotation_map[orientation_key].join(", ")}])" unless rotation_map[orientation_key].nil?
			
			origin = entity.transformation.origin.to_a
			origin.each_index do |i|
				x = origin[i] = origin[i].to_f.round_to(6)
				if x.modulo(1) == 0 #integer
					origin[i] = x.to_i
				else
					rem = x.remainder(1) #remainder
					r,n = 0,0
					(1..5).each do |p|
						r = rem*(2**p)
						n = 2**p
						break if r == r.to_i
					end
					if r == r.to_i and n > 4
						fraction = "#{x.to_i!=0 ? x.to_i : ''}"
						fraction = fraction + "+" if x.to_i!= 0 and r.to_i > 0
						origin[i] = fraction + "#{r.to_i}/#{n.to_f}"
					end
				end
			end
			
			output_string = output_string + ".translate!([#{origin.join(", ")}])"			
			puts output_string
			
		end	
		puts "# -----------------------------------------------"
	end
	
	def dump_camera_coordinates()
		camera = Sketchup.active_model.active_view.camera
		output_string = "("
		output_string += ":eye=>[#{camera.eye.to_a.map{|f| f.round_to(2)}.join(", ")}], "
		output_string += ":target=>[#{camera.target.to_a.map{|f| f.round_to(2)}.join(", ")}], "
		output_string += ":up=>[#{camera.up.to_a.map{|f| f.round_to(2)}.join(", ")}]"
		output_string += ")"
		puts output_string
	end

end

# Create instance and add toolbar
toolbar = UI::Toolbar.new "Kiterpreter"
$kiterpreter = Kiterpreter.new
$kiterpreter.add_tools(toolbar)
toolbar.show
