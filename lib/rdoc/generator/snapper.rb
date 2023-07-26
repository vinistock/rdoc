# frozen_string_literal: true

require "erb"
require "fileutils"
require "pathname"
require_relative "markup"

module RDoc
  module Generator
    class Snapper
      include ERB::Util

      RDoc.add_generator self

      GENERATOR_DIR = File.join("rdoc", "generator")
      VERSION = "1"
      DESCRIPTION = "A modern HTML generator"

      attr_accessor :asset_rel_path
      attr_reader :base_dir
      attr_reader :classes
      attr_accessor :dry_run
      attr_accessor :file_output
      attr_reader :files
      attr_reader :json_index
      attr_reader :methods
      attr_reader :modsort
      attr_reader :store
      attr_reader :template_dir
      attr_reader :outputdir

      def initialize(store, options)
        @store   = store
        @options = options

        @asset_rel_path = ""
        @base_dir = Pathname.pwd.expand_path
        @outputdir = Pathname.new(@options.op_dir).expand_path(@base_dir)
        @dry_run = @options.dry_run
        @file_output = true
        @template_dir = Pathname.new(options.template_dir)
        @template_cache = {}

        @context = nil

        @classes = @store.all_classes_and_modules.sort
        @files   = @store.all_files.sort
        @methods = @classes.flat_map(&:method_list).sort!
        @modsort = @classes.select(&:display?)

        @json_index = JsonIndex.new(self, options)
      end

      # Directory where generated class HTML files live relative to the output dir
      def class_dir
        nil
      end

      # Directory where generated class HTML files live relative to the output dir
      def file_dir
        nil
      end

      # Create the directories the generated docs will live in if they don"t already exist
      def gen_sub_directories
        @outputdir.mkpath
      end

      # Build the initial indices and output objects based on an array of TopLevel objects containing the extracted
      # information
      def generate
        copy_internal_static_files
        generate_index
        generate_class_files
        generate_file_files
        generate_table_of_contents
        @json_index.generate
        @json_index.generate_gzipped
        copy_static
      end

      private

      # Copy internal static files like CSS and JS from the generator's template
      def copy_internal_static_files
        options = { :verbose => $DEBUG_RDOC, :noop => @dry_run }

        ["css/snapper.css", "js/snapper.js"].each do |item|
          destination = "./#{item}"
          FileUtils.mkdir_p(File.dirname(destination), **options)
          FileUtils.cp(@template_dir + item, destination, **options)
        end
      end

      # Copies static files from the static_path into the output directory
      def copy_static
        return if @options.static_path.empty?

        options = { :verbose => $DEBUG_RDOC, :noop => @dry_run }

        @options.static_path.each do |path|
          unless File.directory?(path)
            FileUtils.install(path, @outputdir, **options.merge(mode: 0644))
            next
          end

          Dir.chdir(path) do
            Dir[File.join("**", "*")].each do |entry|
              dest_file = @outputdir + entry

              if File.directory?(entry)
                FileUtils.mkdir_p(entry, **options)
              else
                FileUtils.install(entry, dest_file, **options.merge(mode: 0644))
              end
            end
          end
        end
      end

      # Generate an index page which lists all the classes which are documented
      def generate_index
        template_file = @template_dir + "index.rhtml"
        out_file = @base_dir + @options.op_dir + "index.html"
        rel_prefix = @outputdir.relative_path_from(out_file.dirname)
        search_index_rel_prefix = rel_prefix
        search_index_rel_prefix += @asset_rel_path if @file_output
        asset_rel_prefix = rel_prefix + @asset_rel_path

        @title = @options.title

        render_template(template_file, out_file) do |io|
          here = binding
          # suppress 1.9.3 warning
          here.local_variable_set(:asset_rel_prefix, asset_rel_prefix)
          here
        end
      rescue => e
        error = Error.new("error generating index.html: #{e.message} (#{e.class})")
        error.set_backtrace(e.backtrace)
        raise error
      end

      # Generate a documentation file for each class and module
      def generate_class_files
        template_file = @template_dir + "class.rhtml"

        @classes.each do |klass|
          current = klass
          out_file = @outputdir + klass.path
          rel_prefix = @outputdir.relative_path_from(out_file.dirname)
          search_index_rel_prefix = rel_prefix
          search_index_rel_prefix += @asset_rel_path if @file_output
          asset_rel_prefix = rel_prefix + @asset_rel_path

          @title = "#{klass.type} #{klass.full_name} - #{@options.title}"

          render_template(template_file, out_file) { |io| binding }
        rescue => e
          error = Error.new("error generating #{klass.path}: #{e.message} (#{e.class})")
          error.set_backtrace(e.backtrace)
          raise error
        end
      end

      # Generate a documentation file for each file
      def generate_file_files
        page_file     = @template_dir + "page.rhtml"
        fileinfo_file = @template_dir + "fileinfo.rhtml"

        # for legacy templates
        filepage_file = @template_dir + "filepage.rhtml" unless
          page_file.exist? or fileinfo_file.exist?

        return unless page_file.exist? or fileinfo_file.exist? or filepage_file.exist?

        out_file = nil
        current = nil

        @files.each do |file|
          current = file

          if file.text? and page_file.exist? then
            generate_page file
            next
          end

          template_file = nil
          out_file = @outputdir + file.path
          rel_prefix = @outputdir.relative_path_from out_file.dirname
          search_index_rel_prefix = rel_prefix
          search_index_rel_prefix += @asset_rel_path if @file_output

          asset_rel_prefix = rel_prefix + @asset_rel_path

          unless filepage_file then
            if file.text? then
              next unless page_file.exist?
              template_file = page_file
              @title = file.page_name
            else
              next unless fileinfo_file.exist?
              template_file = fileinfo_file
              @title = "File: #{file.base_name}"
            end
          end

          @title += " - #{@options.title}"
          template_file ||= filepage_file

          render_template(template_file, out_file) { |io| binding }
        end
      rescue => e
        error = Error.new("error generating #{out_file}: #{e.message} (#{e.class})")
        error.set_backtrace(e.backtrace)
        raise error
      end

      # Generate a page file for +file+
      def generate_page(file)
        template_file = @template_dir + "page.rhtml"

        out_file = @outputdir + file.path
        rel_prefix = @outputdir.relative_path_from(out_file.dirname)
        search_index_rel_prefix = rel_prefix
        search_index_rel_prefix += @asset_rel_path if @file_output

        current = file
        asset_rel_prefix = rel_prefix + @asset_rel_path

        @title = "#{file.page_name} - #{@options.title}"
        render_template(template_file, out_file) { |io| binding }
      end

      # Generates the 404 page for the RDoc servlet
      def generate_servlet_not_found(message)
        template_file = @template_dir + "servlet_not_found.rhtml"
        return unless template_file.exist?

        rel_prefix = rel_prefix = ""
        search_index_rel_prefix = rel_prefix
        search_index_rel_prefix += @asset_rel_path if @file_output

        asset_rel_prefix = ""

        @title = "Not Found"
        render_template(template_file) { |io| binding }
      rescue => e
        error = Error.new("error generating servlet_not_found: #{e.message} (#{e.class})")
        error.set_backtrace(e.backtrace)
        raise error
      end

      # Generates the servlet root page for the RDoc servlet
      def generate_servlet_root(installed)
        template_file = @template_dir + "servlet_root.rhtml"
        return unless template_file.exist?

        rel_prefix = "."
        asset_rel_prefix = rel_prefix
        search_index_rel_prefix = asset_rel_prefix
        search_index_rel_prefix += @asset_rel_path if @file_output

        @title = "Local RDoc Documentation"

        render_template(template_file) { |io| binding }
      rescue => e
        error = Error.new("error generating servlet_root: #{e.message} (#{e.class})")
        error.set_backtrace(e.backtrace)
        raise error
      end

      # Generate an index page which lists all the classes which are documented.
      def generate_table_of_contents
        template_file = @template_dir + "table_of_contents.rhtml"
        return unless template_file.exist?

        out_file = @outputdir + "table_of_contents.html"
        rel_prefix = @outputdir.relative_path_from out_file.dirname
        search_index_rel_prefix = rel_prefix
        search_index_rel_prefix += @asset_rel_path if @file_output

        asset_rel_prefix = rel_prefix + @asset_rel_path

        @title = "Table of Contents - #{@options.title}"
        render_template(template_file, out_file) { |io| binding }
      rescue => e
        error = Error.new("error generating table_of_contents.html: #{e.message} (#{e.class})")
        error.set_backtrace(e.backtrace)
        raise error
      end

      # Creates a template from its components and the +body_file+.
      #
      # For backwards compatibility, if +body_file+ contains "<html" the body is
      # used directly.
      def assemble_template(body_file)
        body = body_file.read
        return body if body =~ /<html/

        head_file = @template_dir + "_head.rhtml"
        footer_file = @template_dir + "_footer.rhtml"

        <<~TEMPLATE
          <!DOCTYPE html>

          <html>
          <head>
          #{head_file.read}

          #{body}

          #{footer_file.read}
        TEMPLATE
      end

      # Renders the ERb contained in +file_name+ relative to the template directory and returns the result based on the
      # current context.
      def render(file_name)
        template_file = @template_dir + file_name
        template = template_for(template_file, false, ERBPartial)
        template.filename = template_file.to_s
        template.result(@context)
      end

      # Load and render the erb template in the given +template_file+ and write
      # it out to +out_file+.
      #
      # Both +template_file+ and +out_file+ should be Pathname-like objects.
      #
      # An io will be yielded which must be captured by binding in the caller.
      def render_template(template_file, out_file = nil) # :yield: io
        io_output = out_file && !@dry_run && @file_output
        erb_klass = io_output ? ERBIO : ERB

        template = template_for(template_file, true, erb_klass)

        if io_output
          out_file.dirname.mkpath
          out_file.open("w", 0644) do |io|
            io.set_encoding(@options.encoding)

            @context = yield io
            template_result(template, @context, template_file)
          end
        else
          @context = yield nil
          template_result(template, @context, template_file)
        end
      end

      # Creates the result for +template+ with +context+.  If an error is raised a Pathname +template_file+ will
      # indicate the file where the error occurred
      def template_result(template, context, template_file)
        template.filename = template_file.to_s
        template.result(context)
      rescue NoMethodError => e
        raise Error, "Error while evaluating %s: %s" % [
          template_file.expand_path,
          e.message,
        ], e.backtrace
      end

      # Retrieves a cache template for +file+, if present, or fills the cache
      def template_for(file, page = true, klass = ERB)
        template = @template_cache[file]
        return template if template

        if page
          template = assemble_template(file)
          erbout = "io"
        else
          template = file.read
          template = template.encode(@options.encoding)
          file_var = File.basename(file).sub(/\..*/, "")
          erbout = "_erbout_#{file_var}"
        end

        template = klass.new(template, trim_mode: "-", eoutvar: erbout)
        @template_cache[file] = template
        template
      end
    end
  end
end
