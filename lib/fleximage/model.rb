module Fleximage
  
  # Container for Fleximage model method inclusion modules
  module Model
    
    class MasterImageNotFound < RuntimeError #:nodoc:
    end
    
    # Include acts_as_fleximage class method
    def self.included(base) #:nodoc:
      base.extend(ClassMethods)
    end
    
    # Provides class methods for Fleximage for use in model classes.  The only class method is
    # acts_as_fleximage which integrates Fleximage functionality into a model class.
    module ClassMethods
      
      # Use this method to include Fleximage functionality in your model.  It takes an 
      # options hash with a single required key, :+image_directory+.  This key should 
      # point to the directory you want your images stored on your server.
      def acts_as_fleximage(options = {})
        unless options[:image_directory]
          raise "No place to put images!  Declare this via the :image_directory => 'path/to/directory' option (relative to RAILS_ROOT)"
        end
        
        class_eval <<-CLASS_CODE
          include Fleximage::Model::InstanceMethods
          
          # Where images get stored
          dsl_accessor :image_directory, :default => "#{options[:image_directory]}"
          
          # Put uploads from different days into different subdirectories
          dsl_accessor :use_creation_date_based_directories, :default => true
          
          after_destroy :delete_image_file
          after_save    :save_image_file
        CLASS_CODE
      end
    end
    
    # Provides methods that every model instance that acts_as_fleximage needs.
    module InstanceMethods
      
      # Returns the path to the master image file for this record.
      #   
      #   @some_image.directory_path #=> /var/www/myapp/uploaded_images
      #
      # If this model has a created_at field, it will use a directory 
      # structure based on the creation date, to prevent hitting the OS imposed
      # limit on the number files in a directory.
      #
      #   @some_image.directory_path #=> /var/www/myapp/uploaded_images/2008/3/30
      def directory_path
        # base directory
        directory = "#{RAILS_ROOT}/#{self.class.image_directory}"
        
        # specific creation date based directory suffix.
        creation = self[:created_at] || self[:created_on]
        if self.class.use_creation_date_based_directories && creation 
          "#{directory}/#{creation.year}/#{creation.month}/#{creation.day}"
        else
          directory
        end
      end
      
      # Returns the path to the master image file for this record.
      #   
      #   @some_image.file_path #=> /var/www/myapp/uploaded_images/123.png
      def file_path
        "#{directory_path}/#{id}.png"
      end
      
      # Sets the image file for this record to an uploaded file.  This can 
      # be called directly, or passively like from an ActiveRecord mass 
      # assignment.
      # 
      # Rails will automatically call this method for you, in most of the 
      # situations you would expect it to.
      #
      #   # via mass assignment, the most common form you'll probably use
      #   Photo.new(params[:photo])
      #   Photo.create(params[:photo])
      #
      #   # via explicit assignment hash
      #   Photo.new(:image_file => params[:photo][:image_file])
      #   Photo.create(:image_file => params[:photo][:image_file])
      #   
      #   # Direct Assignment, usually not needed
      #   photo = Photo.new
      #   photo.image_file = params[:photo][:image_file]
      #   
      #   # via an association proxy
      #   p = Product.find(1)
      #   p.images.create(params[:photo])
      #
      # You can also assign a URL to an image, which will make the plugin go
      # and fetch the image at the provided URL.  The image will be stored
      # locally as a master image for that record form then on.
      #
      #   @photo.image_file = 'http://foo.com/bar.jpg'
      def image_file=(file)
        file = open(file) if file =~ %r{^https?://}
        
        if file.respond_to?(:read) && file.size > 0
          # Create RMagick Image object from uploaded file
          if file.path
            @uploaded_image = Magick::Image.read(file.path).first
          else
            @uploaded_image = Magick::Image.from_blob(file.read).first
          end
          
          # Convert to a lossless format for saving the master image
          @uploaded_image.format = 'PNG'
        else
          raise "No file!"
        end
      end
      
      def image_file
        if new_record?
          nil
        else
          if File.exists?(file_path)
            File.open(file_path, 'r+')
          else
            nil
          end
        end
      end
      
      # Call from a .flexi view template.  This enables the rendering of operators 
      # so that you can transform your image.
      #
      #   # app/views/photos/thumb.jpg.flexi
      #   @photo.operate do |image|
      #     image.resize '320x240'
      #   end
      def operate(&block)
        returning self do
          @operating = true
          block.call(self)
          @operating = false
        end
      end
      
      # Load the image from disk, or return the cached and potentially 
      # processed output rmagick image.
      def load_image #:nodoc:
        @output_image ||= Magick::Image.read(file_path).first
      rescue Magick::ImageMagickError => e
        if e.to_s =~ /unable to open file/
          raise MasterImageNotFound, 
            "Master image was not found for this record, so no image can be rendered.\n"+
            "Expected image to be at:\n"+
            "  #{file_path}"
        else
          raise e
        end
      end
      
      # Convert the current output image to a jpg, and return it in 
      # binary form.
      def output_image #:nodoc:
        @output_image.format = 'JPG'
        @output_image.to_blob
      ensure
        GC.start
      end
      
      # If in a view, a call to an unknown method will look for an Operator by that method's name.
      # If it find one, it will execute that operator, otherwise it will simply call super for the
      # default method missing behavior.
      def method_missing(method_name, *args)
        if @operating
          operator_class = "Fleximage::Operator::#{method_name.to_s.camelcase}".constantize
          @output_image = operator_class.new(self).execute(*args)
        else
          super
        end
      rescue NameError => e
        if e.to_s =~ /uninitialized constant Fleximage::Operator::/
          super
        else
          raise e
        end
      end
      
      private
        # Write this image to disk
        def save_image_file
          if @uploaded_image
            FileUtils.mkdir_p(directory_path)
            @uploaded_image.write(file_path)
          end
        ensure
          GC.start
        end
        
        # Delete the image file after this record gets destroyed
        def delete_image_file
          File.delete(file_path)
        end
    end
    
  end
end