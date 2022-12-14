
#!/usr/bin/env ruby
=begin
PodTagger v1.1.0
Copyright Brett Terpstra 2017 | MIT License

# Podtagger: Automated podcast ID3 tagger

<http://brettterpstra.com/projects/podtagger>

Podtagger is a ruby script that reads a `shownotes.raw[.md]` (Markdown with YAML headers) file and applies the information in the headers using configured templates to a target MP3 file.

### Requirements

Podtagger requires [mid3v2](https://mutagen.readthedocs.io/en/latest/man/mid3v2.html) from the Python mutagen package. You can install it with [pip](https://pip.pypa.io/en/stable/). If you don't already have pip installed, use `sudo easy_install pip` before running `sudo pip install mutagen`.

### Changelog

1.1.0 Add title, filesize, and duration metadata to shownotes.md output
=end
require 'yaml'
require 'date'
require 'time'
require 'fileutils'
require 'optparse'
require 'pp'

config_file = File.expand_path("~/.config/podtagger/podtagger.yaml")

def class_exists?(class_name)
  klass = Module.const_get(class_name)
  return klass.is_a?(Class)
rescue NameError
  return false
end

if class_exists? 'Encoding'
  Encoding.default_external = Encoding::UTF_8 if Encoding.respond_to?('default_external')
  Encoding.default_internal = Encoding::UTF_8 if Encoding.respond_to?('default_internal')
end

class PodTagger
  def initialize(file,options)
    @tag_cmd = `which mid3v2`.strip
    if @tag_cmd == ''
      if File.exists?("/usr/local/bin/mid3v2")
        @tag_cmd = "/usr/local/bin/mid3v2"
      # Platypus bundled app version
      elsif File.exists?("#{File.dirname(__FILE__)}/PodTaggerResources/mid3v2")
        @tag_cmd = "#{File.dirname(__FILE__)}/PodTaggerResources/mid3v2"
      else
        output = "Missing executable. Ensure that mid3v2 exists in your path.\n"
        output += "See https://mutagen.readthedocs.io/en/latest/man/mid3v2.html for installation help"
        die(output,2)
      end
    end

    if file && File.exist?(file)
      @file = file
      @base_dir = File.dirname(file)
      @config = options[:config]
      @debug = options[:debug]
      @color = options[:color]
      if options[:verbose]
        @debug = true
        @verbose = true
      end
      @data = get_data
    else
      die("File #{file} does not exist.", 2)
    end
    tagpod
  end

  private

  # level=0: INFO
  # level=1: WARN
  # level=2: ERROR
  # level=3: SUCCESS
  def output(msg,level=0)
    if level < 2 && !@debug
      return
    elsif level < 1 && !@verbose
      return
    end
    color = $default
    case level
    when 0
      color = $info
    when 1
      color = $warn
    when 2
      color = $error
    when 3
      color = $success
    else
      color = $default
    end

    $stderr.printf("%s%s%s\n" % [color, msg, $default])
  end


  def die(msg,level=0)
    output(msg,level)
    # if level == 2
    #   $stderr.puts "#{$info}Usage: #{File.basename(__FILE__)} TARGET.mp3"
    # end
    Process.exit 1
  end

  def empty_config(podcast=nil)
    config =<<EOFILE
  default:
    # Title of podcast
    podcast: #{podcast.nil? ? "PODCAST NAME" : podcast}

    # Name of host(s)
    host: HOST NAME

    # Podcast network name, blank if not applicable
    network: NETWORK

    # Format for adding header to output show notes
    # Any meta key can be used within %% variables
    title_format: "%%title%% with %%guest%%"

    # Format for title added as ID3 tag
    # Any meta key can be used within %% variables
    ep_title_format: "%%title%% with %%guest%% - %%podcast%% %%episode%%"

    # POSIX path to thumbnail image
    logo: PATH/TO/THUMBNAIL

    # Include episode length, filesize as HTML comment in show notes
    include_metadata: false

  ## Optionally add configs for podcast-specific keys
  # #{podcast rescue "PODCAST NAME"}:
  #   ep_title_format: "%%title%% with %%guest%% - %%podcast%% %%episode%%"
  #   title_format: "## %%title%% with %%guest%%"
  #   logo: PATH/TO/THUMBNAIL
EOFILE
    return config
  end

  def load_default(podcast=nil)
    if File.exist?(@config)
      data = YAML.load(IO.read(@config))
      if data.has_key?('default')
        default = data['default']
        if podcast && data.has_key?(podcast)
          default.merge!(data[podcast])
          default['podcast'] = podcast
        elsif default.has_key?('podcast')
          if data[default['podcast']]
            default.merge!(data[default['podcast']])
          else
            die("No configuration for #{podcast}. Please edit #{@config}",2)
          end
        end
        return default
      end
    end
    output("Error: Missing default configuration",2)
    unless File.directory?(File.dirname(@config))
      FileUtils.mkdir_p(File.dirname(@config))
    end
    File.open(@config,'w') do |f|
      f.puts empty_config
    end
    die("Skeleton config written, please edit file #{@config}",3)
  end

  def title_from_h1(input)
    title = input.scan(/^\#{1,2} (.*)/)
    unless title.empty?
      output("=> [Title taken from h1: #{title[0][0]}]\n\n",0)
      input.sub!(/^\#{1,2} (.*)\n+/,'')
      return [title[0][0],input]
    else
      die('No title specified (title)',2)
    end
  end

  def string_from_template(defaults,template)
    if defaults.has_key?(template)
      defaults[template].gsub(/%%(.*?)%%/) {|match|
        m = Regexp.last_match
        if defaults.has_key?(m[1])
          defaults[m[1]]
        else
          die(%Q{Missing value for key '%%#{m[1]}%%' in format string (#{template})},2)
        end
      }
    else
      die("No title format specified (#{template})",2)
    end
  end

  def get_data
    raw = %x{mdls -raw -name kMDItemDurationSeconds "#{@file}"}.strip
    s = ('%.0f' % raw).to_i
    stamp = '%02d:%02d:%02d' % [s/60/60,s/60%60,s%60]
    size = %x{mdls -raw -name kMDItemLogicalSize "#{@file}"}.strip
    {:seconds=>s,:stamp=>stamp,:size=>size}
  end

  def format_data
    out = ['<!-- Metadata']
    out.push("Duration Seconds: #{@data[:seconds]}")
    out.push("Duration: #{@data[:stamp]}")
    out.push("Filesize: #{@data[:size]}")
    out.push("-->\n")
    out.join("\n")
  end

  def tagpod
    files_arr = %w(shownotes.raw shownotes.raw.md)
    shownotes = false
    files_arr.each {|notes|
      if File.exist?(File.join(@base_dir,notes))
        shownotes = File.join(@base_dir,notes)
      end
    }
    unless shownotes
      if File.exist?(File.join(@base_dir,'shownotes.md'))
        shownotes = File.join(@base_dir,'shownotes.raw.md')
        FileUtils.cp File.join(@base_dir,'shownotes.md'), shownotes
      else
        die('No shownotes.raw file exists',2)
      end
    end
    input = IO.read(shownotes).force_encoding('utf-8')

    begin
      data = YAML.load(input)
    rescue Exception => e
      output(e,1)
      output(e.backtrace,0)
      die('Error reading YAML headers in shownotes.raw',2)
    end
    show_notes = input.sub!(/---.*?---/m,'')
    if data.has_key?('podcast')
      defaults = load_default(data['podcast'])
    else
      defaults = load_default
    end
    defaults.merge!(data)

    if @verbose
      output("* [Resolved YAML data]",0)
      output("------------",0)
      $stderr.print($info)
      defaults.each {|k,v|
        $stderr.printf "%15s: %s\n" % [k,v]
      }
      $stderr.print($default)
      output("------------\n\n",0)
    end

    if defaults.has_key?('date')
      t = Time.parse(defaults['date']) rescue die('Invalid date format',2)
      date = t.year
    elsif defaults.has_key?('year')
      if defaults['year'] =~ /\d{4}/
        date = defaults['year']
      else
        die('Invalid year format',2)
      end
    else
      t = Time.now
      date = t.year
    end
    podcast = defaults['podcast']
    description = defaults['description'] || die('No description provided (description)',2)
    episode = defaults['episode'] || die('No episode number specified (episode)',2)
    if defaults.has_key?('title')
      title = defaults['title']
    else
      title, show_notes =  title_from_h1(show_notes)
      defaults['title'] = title
    end
    logo = File.expand_path(defaults['logo']) || die('No logo specified (logo)',2)
    host = defaults['host'] || die('No host specified (host)',2)
    if !defaults.has_key?('network') || defaults['network'].empty?
      network = host
    else
      network = defaults['network']
    end

    ep_title = string_from_template(defaults,'ep_title_format')
    formatted_title = string_from_template(defaults,'title_format')

    args = {
      'TDES' => %Q{"#{description}"},
      'COMM' => %Q{"#{description}"},
      'TALB' => %Q{"#{podcast}"},
      'TCMP' => 1,
      'TCON' => %Q{"Podcast"},
      'TRCK' => %Q{"#{episode}"},
      'APIC' => %Q{"#{logo}"},
      'TPE1' => %Q{"#{network}"},
      'TPE2' => %Q{"#{host}"},
      'TIT2' => %Q{"#{ep_title}"},
      'TDRC' => %Q{"#{date}"}
    }

    cmd = %Q{"#{@tag_cmd}" -D #{@file} && "#{@tag_cmd}"}

    args.each {|k,v|
      cmd += %Q{ --#{k} #{v}}
    }

    cmd += %Q{ "#{@file}"}
    output("* [Command]\n------------\n#{cmd}\n------------\n\n",0)

    %x{#{cmd}}
    output("=> ID3 tags written to #{@file}",3)

    if @verbose
      $stderr.puts("#{$info}------------")
      args.each {|k,v|
        $stderr.printf "   %s: %s\n" % [k, v]
      }
      $stderr.puts("------------#{$default}")
    end

    File.open(File.join(@base_dir,'shownotes.md'),'w') do |f|
      if defaults['include_metadata']
        f.puts format_data
      end
      f.puts ("%s\n\n" % formatted_title)
      f.puts (show_notes)
      output(%Q{Show notes for "#{ep_title}" written to shownotes.md},3)
    end

    %x{osascript -e 'tell app "Finder" to reveal POSIX file "#{File.expand_path(@file)}"'}
  end
end

options = {}
parser = OptionParser.new do |opts|
  opts.banner = output = "Usage: #{File.basename(__FILE__)} [options] TARGET.mp3"
  opts.separator ""
  opts.separator "Options:"

  options[:debug] = false
  opts.on( '-d','--debug', 'Show debug output' ) do
    options[:debug] = true
  end

  options[:verbose] = false
  opts.on( '-v','--verbose', 'Verbose output' ) do
    options[:verbose] = true
    $stderr.puts "Verbose output"
  end

  options[:config] = config_file
  opts.on( '-c CONFIG','--config=CONFIG', 'Use alternate configuration file' ) do |config|
    options[:config] = File.expand_path(config)
  end

  options[:color] = true
  opts.on( '--no-color', 'Colorize output (default)' ) do
    options[:color] = false
  end

  options[:html] = false
  opts.on( '--html', 'Output HTML status messages' ) do
    options[:color] = false
    options[:html] = true
  end

  opts.on( '-h', '--help', 'Display this screen' ) do
    puts opts
    exit
  end
end

parser.parse!

if options[:color]
  $info    = "\033[1;37m"
  $success  = "\033[1;32m"
  $warn  = "\033[1;33m"
  $error  = "\033[1;31m"
  $default = "\033[0;39m"
elsif options[:html]
  $info = '<pre style="color:#aaa">'
  $success = '<pre style="color:green;background:#eee">'
  $warn = '<pre style="color:orange">'
  $error = '<pre style="color:white;background:red">'
  $default= '</pre>'
else
  $info = ""
  $success = ""
  $warn = ""
  $error = ""
  $default= ""
end

if options[:config] != config_file
  if File.exists?(options[:config])
    $stderr.puts "#{$info}Using config file #{options[:config]}#{$default}" if options[:verbose]
  else
    $stderr.puts "#{$error}Configuration file #{options[:config]} does not exist#{$default}"
    parser.parse %w[-h]
    Process.exit 1
  end
end

if ARGV.length > 0 && File.exist?(ARGV[0])
  if ARGV[0] =~ /mp3$/
    $stderr.puts('<body style="background:#333;color:#fff;font-size:16px">') if options[:html]
    PodTagger.new(ARGV[0],options)
    $stderr.puts('</body>') if options[:html]
  else
    $stderr.puts "#{$error}Target file must have mp3 extension#{$default}"
    Process.exit 1
  end
else
  if ARGV.length > 0 && !File.exist?(ARGV[0])
    $stderr.puts "#{$error}File #{ARGV[0]} doesn't exist#{$default}"
  else
    $stderr.puts "#{$error}No mp3 filename provided#{$default}"
  end
  parser.parse %w[-h]
  Process.exit 1
end