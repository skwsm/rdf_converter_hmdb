#!/usr/bin/env ruby

require 'pp'
require 'optparse'
require 'rexml/document' 

module HMDB

  def prefixes
    [": <https://hmdb.ca/metabolites/>",
     "ont: <http://purl.jp/hmdb/ontology/>",
     "m2r: <http://med2rdf.org/ontology/med2rdf#>",
     "rdfs: <http://www.w3.org/2000/01/rdf-schema#>",
     "dct: <http://purl.org/dc/terms/>",
     "identifiers: <http://identifiers.org/>",
     "skos: <http://www.w3.org/2004/02/skos/core#>",
     "obo: <http://purl.obolibrary.org/obo/>",
     "taxon: <http://identifiers.org/taxonomy/>",
     "sio: <http://semanticscience.org/resource/>",
     "up: <http://purl.uniprot.org/uniprot/>",
     "xsd: <http://www.w3.org/2001/XMLSchema#>",
     "pubmed: <http://rdf.ncbi.nlm.nih.gov/pubmed/>",
     "chemont: <http://classyfire.wishartlab.com/tax_nodes/>",
    ].each {|uri| print "@prefix #{uri} .\n"}
    print "\n"
  end

  def date_helper(str)
    case str
    when /^(\d\d\d\d\-\d\d\-\d\d)/
      $1
    else
      str
    end
  end
  module_function :prefixes, :date_helper

  class Metabolites

    def initialize(metabolite_file_path, chemont_file_path)
      @chemont_label2id = {}
      File.open(metabolite_file_path) do |file|
        @xml = REXML::Document.new(file)
      end
      File.open(chemont_file_path) do |file|
        parse_chemont(file)  
      end
      @ontology = Ontology.new
    end
    attr_accessor :xml, :chemont, :ontology, :chemont_label2id

    def parse_metabolites
      @xml.elements['hmdb'].each_element do |metabolite|
        m = Metabolite.new(metabolite, @chemont_label2id)
        m.parse_record_information
        m.parse_metabolite_identification
        m.parse_chemical_taxonomy
        m.parse_concentrations(m.get_block('//normal_concentrations'))
        @ontology.parse(m.get_block('//ontology'))
        m.puts_turtle
      end
    end

    def parse_chemont(file)
      while line = file.gets
        case line
	when /^id: CHEMONTID:(.+)\n$/ 
 	  chemont_id = "C#{$1}"
 	when /^name: (.+)\n$/ 
 	  @chemont_label2id[$1] = chemont_id
        else 
        end
      end
    end

    def puts_ontology
      @ontology.puts_ontology
    end

  end

  class Metabolite

    def initialize(metabolite, chemont_label2id)
      @xml = metabolite
      @chemont_label2id = chemont_label2id
      @accession = @xml.elements['accession'].text
      @triples = []
    end
    attr_accessor :xml, :accession, :triples, :chemont_label2id

    def parse_record_information
      @triples << [":#{@accession}", "dct:identifier", "\"#{@accession}\""]
      @triples << [":#{@accession}", "ont:version", "\"#{@xml.elements['version'].text}\""]
      @triples << [":#{@accession}", "ont:status", "\"#{@xml.elements['status'].text}\""]
      @triples << [":#{@accession}", "dct:created", "\"#{HMDB.date_helper(@xml.elements['creation_date'].text)}\"^^xsd:date"]
      @triples << [":#{@accession}", "dct:modified", "\"#{HMDB.date_helper(@xml.elements['update_date'].text)}\"^^xsd:date"]
      @xml.elements['secondary_accessions'].each_element do |secondary_accession|
        @triples << [":#{@accession}", "ont:secondary_accession", "\"#{secondary_accession.text}\""]
      end
    end

    def parse_metabolite_identification
      @triples << [":#{@accession}", "rdfs:label", "\"#{@xml.elements['name'].text}\""]
      @triples << [":#{@accession}", "skos:description", "\"\"\"#{@xml.elements['description'].text}\"\"\"@en"]
      @xml.elements['synonyms'].each_element do |synonym|
        @triples << [":#{@accession}", "skos:altLabel", "\"#{synonym.text}\"@en"]
      end
    end

    def parse_chemical_taxonomy
#      @accession = @xml.elements['accession'].text
      @xml.elements['//taxonomy'].each_element do |elm|
        case elm.name
        when 'direct_parent'
          @triples << [":#{@accession}", "a", "chemont:#{@chemont_label2id[elm.text]}"]
        when 'description'
        when 'alternative_parents'
        when 'substituents'
        else
        end
      end
    end

    def parse_concentrations(block)
      block.each_element do |concentration|
        @triples << [":#{@accession}", "ont:concentration", "["]
        concentration.each_element do |elm|
          case elm.name
          when 'biospecimen'
            @triples << ["ont:biospecimen", "\"#{elm.text}\""]
          when 'concentration_value'
            @triples << ["ont:concentration_value", "\"#{elm.text}\""]
          when 'concentration_units'
            @triples << ["ont:concentration_units", "\"#{elm.text}\""]
          when 'subject_condition'
            @triples << ["ont:subject_condition", "\"#{elm.text}\""]
          when 'subject_age'
            @triples << ["ont:subject_age", "\"#{elm.text}\""]
          when 'subject_sex'
            @triples << ["ont:subject_sex", "\"#{elm.text}\""]
          when 'references'
            elm.each_element{|ref| 
              if ref.elements['pubmed_id'] != nil
                @triples << ["dct:references", "pubmed:#{ref.elements['pubmed_id'].text}"]
              end
            }
          end
        end
        @triples << ["] ."]
      end
    end

    def get_block(elm_path)
      return @xml.elements[elm_path]
    end

    def puts_turtle
      @triples.each do |triple|
        case triple.size
        when 3
          if triple[2] == "["
            print "#{triple.join(" ")}\n"
          else
            print "#{triple.join(" ")} .\n"
          end
        when 2
          print "#{triple.join(" ")} ;\n"
        when 1
          print "#{triple.join(" ")}\n"
        else
          STDERR.print "Unknown patter!\n"
        end
      end
    end
  end

  class Ontology

    def initialize()
      @data = {}
    end
    attr_accessor :data

    def parse(xml_element)
      xml_element.each_element do |root|
        parse_path(root, "root")
      end
    end

    def parse_path(ontology_term, parent_term)
      self_term = ""
      ontology_term.each_element do |e|
        case e.name
        when 'term'
          self_term = e.text.downcase.gsub(" ", "_").to_sym
          unless @data.key?(self_term)
            @data[self_term] = {:term => "#{e.text}"}
            @data[self_term][:sub_class_of] = parent_term
          end
        when 'definition'
          unless e.text == nil
            @data[self_term][:definition] = "#{e.text}" unless @data[self_term].key?(:definition)
          end
        when 'parent_id'
          unless e.text == nil
            @data[parent_term][:id] = "#{e.text}" unless @data[parent_term].key?(:id)
            @data[parent_term][:sub_class_of] = "#{parent_term}" unless @data[parent_term].key?(:sub_class_of)
          end
        when 'level'
        when 'type'
        when 'synonyms'
          unless e.text == nil
            unless @data[self_term].key?(:synonyms)
              @data[self_term][:synonyms] = []
              e.each_element do |synonym|
                @data[self_term][:synonyms] << synonym.text
              end
            end
          end
        when 'descendants'
          e.each_element do |child|
            parse_path(child, self_term)
          end
        else
        end
      end
    end

    def puts_ontology
      ont = "ont"
      @data.each do |key, value|
        value.each do |k, v|
          case k
          when :term
            print "#{ont}:#{key} rdfs:label \"#{v}\"@en .\n"
          when :definition
            print "#{ont}:#{key} skos:definition \"#{v}\"@en .\n"
          when :id
            print "#{ont}:#{key} dct:identifier \"#{v}\" .\n"
          when :sub_class_of
            print "#{ont}:#{key} rdfs:subClassOf :#{v} .\n"
          when :synonyms
            v.each do |synonym|
              print "#{ont}:#{key} skos:altLabel \"#{synonym}\"@en .\n"
            end
          end
        end
      end
    end
  end


end


def help
  print "Usage: ruby rdf_converter_hmdb.rb [options]\n"
  print "  -i, --input   path to a HMDB metabolite XML file\n"
  print "  -c, --chemont path to a chmeont obo file\n"
  print "  -h, --help    show help\n"
end


params = ARGV.getopts('i:c:h', 'input:', 'chemont:', 'help')

if (params["input"] && params["chemont"])
  m = HMDB::Metabolites.new(params["input"], params["chemont"])
  HMDB.prefixes
  m.parse_metabolites
  m.puts_ontology
elsif (params["i"] && params["c"])
  m = HMDB::Metabolites.new(params["i"], params["c"])
  HMDB.prefixes
  m.parse_metabolites
  m.puts_ontology
elsif (params["h"] || params["help"])
  help
  exit
end

#metabolite_file_path = ARGV.shift
#chemont_file_path = ARGV.shift

#m = HMDB::Metabolites.new(metabolite_file_path, chemont_file_path)
#m.parse_metabolites
#m.puts_ontology



