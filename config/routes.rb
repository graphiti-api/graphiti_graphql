GraphitiGraphQL::Engine.routes.draw do
  # Default json so our error handler takes effect
  scope defaults: {format: :json} do
    post "/" => "execution#execute"
  end
end
