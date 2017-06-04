defmodule Kronky.Payload do
  @moduledoc """
  Absinthe Middleware to build a mutation payload response.

  Kronky mutation responses (aka "payloads") have three fields

  - `successful` - Indicates if the mutation completed successfully or not. Boolean.
  - `messages` - a list of validation errors. Always empty on success
  - `result` - the data object that was created/updated/deleted on success. Always nil when unsuccesful


  ## Usage

  In your schema file

  1. `import Kronky.Payload`
  2. `import_types Kronky.ValidationMessageTypes`
  3. create a payload object for each object using `payload_object(payload_name, object_name)`
  4. create a mutation that returns the payload object. Add the payload middleware after the resolver.
    ```
    field :create_user, type: :user_payload, description: "add a user" do
      arg :user, :create_user_params
      resolve &UserResolver.create/2
      middleware &build_payload/2
    end
    ```

  ## Example Schema

  Object Schema:

  ```elixir

  defmodule MyApp.Schema.User do
    @moduledoc false

    use Absinthe.Schema.Notation
    import Kronky.Payload
    import_types Kronky.ValidationMessageTypes

    alias MyApp.Resolvers.User, as: UserResolver

    object :user, description: "Someone on our planet" do
      field :id, non_null(:id), description: "unique identifier"
      field :first_name, non_null(:string), description: "User's first name"
      field :last_name, :string, description: "Optional Last Name"
      field :age, :integer, description: "Age in Earth years"
      field :inserted_at, :time, description: "Created at"
      field :updated_at, :time, description: "Last updated at"
    end

    input_object :create_user_params, description: "create a user" do
      field :first_name, non_null(:string), description: "Required first name"
      field :last_name, :string, description: "Optional last name"
      field :age, :integer, description: "Age in Earth years"
    end

    payload_object(:user_payload, :user)

    object :user_mutations do

      field :create_user, type: :user_payload, description: "Create a new user" do
        arg :user, :create_user_params
        resolve &UserResolver.create/2
        middleware &build_payload/2
      end
    end
    ```

    In your main schema file

    ```
    import_types MyApp.Schema.User

    mutation do
     ...
     import_fields :user_mutations
    end
    ```

    """

  @enforce_keys [:successful]
  defstruct [successful: nil, messages: [], result: nil]
  alias __MODULE__
  alias Kronky.ValidationMessage
  import Kronky.ChangesetParser
  use Absinthe.Schema.Notation

  @doc """
  Create a payload object definition

  Each object that can be mutated will need it's own graphql response object
  in order to return typed responses.  This is a helper method to generate a
  custom payload object

  ## Usage

      payload_object(:user_payload, :user)

  is the equivalent of

  ```elixir
  object :user_payload do
    field :successful, non_null(:boolean), description: "Indicates if the mutation completed successfully or not. "
    field :messages, list_of(:validation_message), description: "A list of failed validations. May be blank or null if mutation succeeded."
    field :result, :user, description: "The object created/updated/deleted by the mutation"
  end
  ```

  This method must be called after `import_types Kronky.MutationTypes` or it will fail due to `:validation_message` not being defined.
  """
  defmacro payload_object(payload_name, result_object_name) do
    quote location: :keep do

      object unquote(payload_name) do
        field :successful, non_null(:boolean), description: "Indicates if the mutation completed successfully or not. "
        field :messages, list_of(:validation_message), description: "A list of failed validations. May be blank or null if mutation succeeded."
        field :result, unquote(result_object_name), description: "The object created/updated/deleted by the mutation"
      end
    end
  end

  @doc """
  Convert a resolution value to a mutation payload

  To be used as middleware by Absinthe.Graphql. It should be placed immediatly after the resolver.

  The middleware will automatically transform an invalid changeset into validation errors.

  Your resolver could then look like:

  ```elixir
  @doc "
  Creates a new user

  Results are wrapped in a result monad as expected by absinthe.
  "
  def create(%{user: attrs}, _resolution) do
    case UserContext.create_user(attrs) do
      {:ok, user} -> {:ok, user}
      {:error, %Ecto.Changeset{} = changeset} -> {:ok, changeset}
    end
  end
  ```

  The build payload middleware will also accept error tuples with single or lists of
  `Kronky.ValidationMessage` or string errors. However, these will need to be wrapped in
  an :ok tuple or they will be seen as errors by graphql.

  An example resolver could look like:

  ```
  @doc "gets a user by id

  Results are wrapped in a result monad as expected by absinthe.
  "
  def get(%{id: id}, _resolution) do
    case UserContext.get_user(id) do
      nil -> {:ok, {:error, %ValidationMessage{key: :id, code: "not found", message: "does not exist"}}}
      user -> {:ok, user}
    end
  end
  ```

  Valid formats are:
  ```
  {:error, %ValidationMessage{}}
  {:error, [%ValidationMessage{},%ValidationMessage{}]}
  {:error, "This is an error"}
  {:error, ["This is an error", "This is another error"]}
  ```
  """
  def build_payload(%{value: value} = resolution, _config) do
    result = build_from_value(value)
    Absinthe.Resolution.put_result(resolution, {:ok, result})
  end

  defp build_from_value({:error, %ValidationMessage{} = message}) do
    message |> error_payload
  end

  defp build_from_value({:error, message}) when is_binary(message) do
    message |> generic_validation_message() |> error_payload
  end

  defp build_from_value({:error, list}) when is_list(list), do: error_payload(list)

  defp build_from_value(%Ecto.Changeset{valid?: false} = changeset) do
    changeset |> extract_messages() |> error_payload
  end

  defp build_from_value(value), do: success_payload(value)

  @doc """
  Generates a mutation error payload.

  ## Examples

      iex> error_payload(%ValidationMessage{code: "required", field: "name"})
      %Payload{successful: false, messages: [%ValidationMessage{code: "required", field: "name"}]}

      iex> error_payload([%ValidationMessage{code: "required", field: "name"}])
      %Payload{successful: false, messages: [%ValidationMessage{code: "required", field: "name"}]}

  """
  def error_payload(%ValidationMessage{} = message), do: error_payload([message])
  def error_payload(messages) when is_list(messages) do
    messages = messages |> Enum.map(&prepare_message/1)
    %Payload{successful: false, messages: messages}
  end

  @doc "convert validation message key to camelCase format used by graphQL"
  def convert_key(%ValidationMessage{} = message) do
    key = case message.key do
      nil -> nil
      key -> Inflex.camelize(key, :lower)
    end
    %{message | key: key}
  end

  defp prepare_message(%ValidationMessage{} = message) do
    convert_key(message)
  end

  defp prepare_message(message) when is_binary(message) do
    generic_validation_message(message)
  end

  defp prepare_message(message) do
    raise ArgumentError, "Unexpected validation message: #{inspect(message)}"
  end

  @doc """
  Generates a success payload.

  ## Examples

      iex> success_paylaod(%User{first_name: "Stich", last_name: "Pelekai", id: 626})
      %Payload{successful: true, result: %User{first_name: "Stich", last_name: "Pelekai", id: 626}}

  """
  def success_payload(result) do
    %Payload{successful: true, result: result}
  end

  defp generic_validation_message(message) do
    %ValidationMessage{
      code: :unknown, key: nil, template: message, message: message, options: []
    }
  end

end