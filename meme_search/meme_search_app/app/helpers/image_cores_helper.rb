module ImageCoresHelper
  def absolute_image_path(image_core)
    image_name = image_core.name
    # The image path name may be nested ("telegram/grbit"); escape per segment so the separators survive.
    segments = image_core.image_path.name.split("/").reject(&:blank?) + [ image_name ]
    url_path = segments.map { |segment| ERB::Util.url_encode(segment) }.join("/")
    absolute_path = "#{request.protocol}#{request.host_with_port}/memes/#{url_path}"
    return absolute_path, image_name
  end
end
