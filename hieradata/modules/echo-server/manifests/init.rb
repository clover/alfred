class EchoServer
  attr_accessor :service_name,
                :port,
                :host_tag

  def initialize()
    @service_name = nil
    @port = nil
    @host_tag= nil
  end
end
