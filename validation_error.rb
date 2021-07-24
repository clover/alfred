class ValidationError < StandardError
  def initialize(msg = nil)
    super(message)
  end
end