require 'rubygems'
require 'i18n'
require 'ftools'
require ENV['TM_SUPPORT_PATH'] + '/lib/ui.rb'
require ENV['TM_BUNDLE_SUPPORT'] + '/lib/extensions'
require ENV['TM_BUNDLE_SUPPORT'] + '/bundle_config'

class TranslationHelper
  attr_accessor :locale, :preferences, :options, :store
  
  def initialize(options = {})
    self.options = {}
    self.options[:translation_nib] = "#{ENV['TM_BUNDLE_SUPPORT']}/nibs/input_translation.nib"
    self.preferences = Preferences.new(CONFIG[:bundle_preferences_path])
    
    select_locale
    self.store = YAMLStore.new(self.locale, CONFIG[:locale_file_path])
  end
  
  def add_translation
    original_text = ENV['TM_SELECTED_TEXT'] || ""
    translation = original_text.gsub(/^(['"])(.+)(\1)$/, '\2')
    
    default_scope = self.preferences[:last_key].split('.')[0..-2].join('.')

    view_key = false # determine whether we can shorten what we insert
    if ENV['TM_FILEPATH'] =~ /\/views\/([^\.]+)/
      view_key = true
      default_scope = $1.split('/').join('.')
    elsif ENV['TM_FILEPATH'] =~ /\/models\/([^\.]+)/
      default_scope = $1.split('/').join('.')
    elsif ENV['TM_FILEPATH'] =~ /\/controllers\/([^\.]+)/
      default_scope = $1.split('/').join('.')
    elsif ENV['TM_FILEPATH'] =~ /\/mailers\/([^\.]+)/
      default_scope = $1.split('/').join('.')
    elsif ENV['TM_FILEPATH'] =~ /\/mailer_views\/([^\.]+)/
      # view_key is false because the controller can't be inferred
      default_scope = $1.split('/').join('.')
    end
    # attempt to auto-generate interpolations
    interpolated_translation = translation
    interpolations = []
    translation.scan(/(<%=([^%]+)%>)/).each do |interpolation|
      tokens = interpolation[1].gsub(/[^\w]/,' ').split(' ').compact # make a rough guess at a meaningful key
      int_key = tokens.size > 2 ? tokens[-2] : tokens.last
      interpolated_translation.gsub!(interpolation[0],"%{#{int_key}}")
      interpolations << interpolation[1].strip
    end

    default_specific_key = interpolated_translation.gsub(/[^\w ]/,'').gsub('-','_').split(' ')[0..3].join('_').downcase
    default_key = default_scope + '.' + default_specific_key

    key, translation, interpolations = prompt_for_translation(default_key, interpolated_translation, interpolations)
    if key
      self.preferences[:last_key] = key
      self.store = find_store(key)
      insertion_type = prompt_for_insertion_type
        
      print original_text and return if insertion_type.blank?
      replacement = build_replacement_snippet(insertion_type, key, translation, interpolations, view_key && key.split('.')[0..-2].join('.') == default_scope)

      translation = remove_surrounding_quotes(translation)

      begin
        self.store[key] = translation
        log_translation(key, translation) if CONFIG[:log_changes]
        print replacement
        return
      rescue Exceptions::DuplicateKey
        if (prompt_for_overwrite(self.store[key], translation))
          self.store.send(:[]=, key, translation, true)
          print replacement
          return
        end
      end
    end
    print original_text
  end
  
  def find_store(key)
    scope_arr = key.split('.')[0..-2]
    base_path = "#{ENV['TM_PROJECT_DIRECTORY']}/config/locales/"
    relative_path = 'defaults.en.yml'
    if ENV['TM_FILEPATH'] =~ /\/app\/([^\.]+)/
      relative_path = $1 + '.en.yml'
    end
    path = base_path + relative_path
    dir = path.split('/')[0..-2].join('/')
    unless File.exists?(path)
      File.makedirs(dir) unless File.exists?(dir)
      File.open(path,"w") do |f|
        f << "---\n#{CONFIG[:locale].to_s}:\n  {}" 
      end
    end
    YAMLStore.new(self.locale, path)
  end
  
  def check
    if (ENV['TM_SELECTED_TEXT'])
      print check_one
    else 
      print check_all
    end
  end
    
  private
  
  def prompt_for_overwrite(current_value, new_value)
    overwrite = TextMate::UI.request_confirmation(:button1 => 'Overwrite', :button2 => 'Cancel', :title => 'You have already used this translation key',
    :prompt => "Current Value: #{current_value} \n" + "New Value: #{new_value}\n" + "Continue with overwrite?")
    
    return overwrite
  end
  
  def prompt_for_translation(key = "", translation = "", interpolations = [])
    key, translation, interpolations = TextMate::UI.dialog1(
      :nib => self.options[:translation_nib], 
      :parameters => {'translation' => translation, 'key' => key, 'interpolations' => interpolations},  
      :options => {:center => true, :modal => true}
    ) do |results|
        if (results['returnButton'] == "Save")
          return results['key'], results['translation'], results['interpolations']
        else
          # a button was not clicked (window closed, etc), or cancel was clicked
        end        
    end
    
    return key, translation, interpolations
  end
  
  def prompt_for_insertion_type
    insertion_type = TextMate::UI.request_string(:title => 'Type', :prompt => 'Insert this as html, haml, string, or ruby?', :default => self.preferences[:last_insertion_type])
    # type = TextMate::UI.menu ["html","string","ruby", "haml"]
    self.preferences[:last_insertion_type] = insertion_type #unless insertion_type.blank?
    
    return insertion_type
  end
  
  def select_locale
    # select locale here
    self.locale = CONFIG[:locale]
    
    I18n.locale = self.locale
    I18n.load_path << CONFIG[:locale_file_path]
  end
  
  def translation_method
    current_file = ENV['TM_FILEPATH'].gsub(CONFIG[:project_directory], '')
    
    method = ""
    method << "I18n." unless (current_file =~ /^\/app\/(controllers|helpers|views)\//)
    method << (CONFIG[:method_style] == :short ? "t" : "translate")
    
    return method
  end
  
  def build_replacement_snippet(type, key, translation, interpolations, shorten_scope)
    key = '.' + key.split('.').last if shorten_scope
    arguments = "'#{key}'"
    translation.scan(/\%\{(\w+)\}/).flatten.each_with_index do |interpolation, count|
      arguments << ", :#{interpolation} => #{interpolations[count]}"
    end
    
    case type
      when 'html'
        replacement = "<%=#{translation_method}(#{arguments}) %>"
      when 'string'
        replacement = "\#{#{translation_method}(#{arguments})}"
      when 'haml'
        replacement = "= #{translation_method}(#{arguments})"
      else
        replacement = "#{translation_method}(#{arguments})"
    end
  end
  
  def check_one
    def method_missing(method, *args)
      "##{method}()"
    end

    class << Object
      def const_missing(const)
        nil
      end
    end
    
    #TODO figure out how to handle instance variable undefined warnings from leakking through
    args = eval('args_to_array(' + ENV['TM_SELECTED_TEXT'].gsub(/^\s*(\()|(\))\s*$/, '') + ')')
    
    return I18n.translate(*args) rescue "INVALID KEY: #{args.first}"
  end
  
  def check_all
    keys = []

    # Collect the lines
    File.open(ENV['TM_FILEPATH'], "r") do |file|
      file.each_line do |line|
         keys << line  if (line =~ /translate\(|\bt\(/)
      end
    end
  
    # Find the keys
    matches = keys.collect do |key|
      # TODO: This should also match symbols
      (key.scan(/(?:I18n\.)?(?:(?:translate|t)\()(['"][\w\.-_]+['"])/)) rescue ""       
    end
    
    translations = matches.flatten.inject([]) do |memo, keys|
      arguments = eval('args_to_array(' + keys.to_s + ')')
      arguments.last.each { |k, v| arguments.last[k] = "**#{k}**" if v.nil? } if arguments.last.is_a?(Hash)
      translation = I18n.translate(*arguments) rescue "INVALID KEY"
      memo << "#{keys} => #{translation}"
    end
    
    return translations.join("\n")
  end
  
  def args_to_array(*args)
    args # this seems a little clever, but it acheives its purpose
  end
  
  def remove_surrounding_quotes(text)
    return text.gsub(/^\s*("|')|("|')\s*$/, "")
  end 
  
  def log_translation(key, translation)
    `echo "#{key}:#{translation}" >> #{CONFIG[:log_file_path]}`
  end
end
