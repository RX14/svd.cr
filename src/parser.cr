require "xml"
require "./model/device"

class XML::Node
  def child?(name : String) : XML::Node?
    children.find { |n| n.name == name }
  end

  def child(name : String) : XML::Node
    children.find! { |n| n.name == name }
  end

  def children(name : String) : Array(XML::Node)
    children.select { |n| n.name == name }
  end
end

module SVD
  def self.parse(source) : SVD::Device
    xml = XML.parse(source)
    node = xml.child("device")

    partial_rp = parse_register_properties(node, RegisterProperties::Partial.new)

    peripherals = node.child("peripherals").children("peripheral").map do |node|
      parse_peripheral(node, partial_rp)
    end

    SVD::Device.new(
      schema_version: node["schemaVersion"].to_f,
      licence_text: format_doc(node.child?("licenseText")),
      register_properties: partial_rp,
      peripherals: peripherals,
    )
  end

  protected def self.parse_peripheral(
    node : XML::Node,
    parent_rp : RegisterProperties::Partial
  ) : SVD::Peripheral
    partial_rp = parse_register_properties(node, parent_rp)

    if reg_node = node.child?("registers")
      registers = reg_node.children("register").map do |node|
        parse_register(node, partial_rp)
      end

      clusters = reg_node.children("cluster").map do |node|
        parse_cluster(node, partial_rp)
      end
    else
      registers = Array(SVD::Register).new
      clusters = Array(SVD::Cluster).new
    end

    SVD::Peripheral.new(
      name: node.child("name").content,
      version: node.child?("version").try(&.content),
      description: format_doc(node.child?("description")),
      base_address: scaled_uint(node.child("baseAddress")),
      register_properties: partial_rp,
      registers: registers,
      clusters: clusters,
    )
  end

  protected def self.parse_cluster(
    node : XML::Node,
    parent_rp : RegisterProperties::Partial,
  )
    partial_rp = parse_register_properties(node, parent_rp)

    registers = node.children("register").map do |node|
      parse_register(node, partial_rp)
    end

    SVD::Cluster.new(
      name: node.child("name").content,
      description: format_doc(node.child?("description")),
      address_offset: scaled_uint(node.child("addressOffset")),
      register_properties: partial_rp,
      registers: registers,
      dim: parse_dim(node),
    )
  end

  protected def self.parse_register(
    node : XML::Node,
    parent_rp : RegisterProperties::Partial,
  ) : SVD::Register
    partial_rp = parse_register_properties(node, parent_rp)

    if fields_node = node.child?("fields")
      fields = fields_node.children("field").map do |node|
        parse_field(node, partial_rp)
      end
    else
      fields = Array(SVD::Field).new
    end

    SVD::Register.new(
      name: node.child("name").content,
      description: format_doc(node.child?("description")),
      address_offset: scaled_uint(node.child("addressOffset")),
      properties: partial_rp.to_register_properties,
      access: partial_rp.access,
      fields: fields,
      dim: parse_dim(node)
    )
  end

  protected def self.parse_field(
    node : XML::Node,
    parent_rp : RegisterProperties::Partial?,
  ) : SVD::Field
    partial_rp = parse_register_properties(node, parent_rp)

    if bit_range = node.child?("bitRange")
      bit_range = bit_range.content

      raise "Invalid bitRange" unless bit_range.starts_with?('[') && bit_range.ends_with?(']')

      msb, _, lsb = bit_range[1..-2].partition(':')
      bit_offset = lsb.to_i
      bit_width = msb.to_i - bit_offset + 1
    elsif bit_offset = scaled_uint(node.child?("bitOffset")).try(&.to_i)
      bit_width = scaled_uint(node.child("bitWidth")).try(&.to_i)
    else
      raise "No bit offset/width for #{node.child("name").content}"
    end

    if ev_node = node.child?("enumeratedValues")
      enumerated_values = ev_node.children("enumeratedValue").map do |node|
        parse_enumerated_value(node)
      end
    else
      enumerated_values = Array(Field::EnumeratedValue).new
    end

    SVD::Field.new(
      name: node.child("name").content,
      description: format_doc(node.child?("description")),
      bit_offset: bit_offset,
      bit_width: bit_width,
      access: partial_rp.access.not_nil!,
      enumerated_values: enumerated_values,
    )
  end

  protected def self.parse_enumerated_value(node : XML::Node) : SVD::Field::EnumeratedValue
    Field::EnumeratedValue.new(
      name: node.child("name").content,
      description: format_doc(node.child?("description")),
      value: scaled_uint(node.child("value")),
    )
  end

  protected def self.parse_register_properties(
    node : XML::Node,
    parent : RegisterProperties::Partial
  ) : RegisterProperties::Partial
    size = scaled_uint(node.child?("size"))
    access = node.child?("access").try do |n|
      RegisterProperties::Access.parse(n.content)
    end
    protection = node.child?("protection").try do |n|
      RegisterProperties::Protection.parse(n.content)
    end
    reset_value = scaled_uint(node.child?("resetValue"))
    reset_mask = scaled_uint(node.child?("resetMask"))

    RegisterProperties::Partial.new(
      size: size || parent.size,
      access: access || parent.access,
      protection: protection || parent.protection,
      reset_value: reset_value || parent.reset_value,
      reset_mask: reset_mask || parent.reset_mask,
    )
  end

  protected def self.parse_dim(node : XML::Node) : Dim?
    size = scaled_uint(node.child?("dim"))
    return unless size

    address_increment = scaled_uint(node.child("dimIncrement"))
    impl_name = node.child?("dimName").try(&.content)

    SVD::Dim.new(
      size: size.to_i,
      address_increment: address_increment,
      impl_name: impl_name
    )
  end

  protected def self.format_doc(node : XML::Node) : String
    node.content.delete('\n').split("\\n").map(&.strip).join("\n")
  end

  protected def self.format_doc(node : Nil) : Nil
    nil
  end

  # parse a SVD scaledNonNegativeInteger
  protected def self.scaled_uint(node : XML::Node) : UInt64
    content = node.content.lstrip('+')

    case content[-1]
    when 'k', 'K' then unit = 1024
    when 'm', 'M' then unit = 1024**2
    when 'g', 'G' then unit = 1024**3
    when 't', 'T' then unit = 1024**4
    else               unit = 1
    end

    num = content.rstrip("kmgtKMGT")

    if num.starts_with? '#'
      num = num.lstrip('#').to_u64(base: 2)
    else
      num = num.downcase.to_u64(base: 10, prefix: true) # prefix: true handles 0x, downcase handles 0X
    end

    num * unit
  end

  protected def self.scaled_uint(node : Nil) : Nil
    nil
  end
end
