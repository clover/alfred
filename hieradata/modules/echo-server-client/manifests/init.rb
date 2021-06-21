class EchoServerClient
  attr_accessor :service_name,
                :port

  def initialize
    @service_name = nil
    @port = nil
    @modules = ['echo-server']
  end
end
