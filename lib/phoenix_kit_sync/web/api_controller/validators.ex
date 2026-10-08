defmodule PhoenixKitSync.Web.ApiController.Validators do
  @moduledoc """
  Parameter validators for the sync REST API endpoints.

  Each validator accepts the raw `params` map from the Phoenix controller
  action, checks that the required fields are present and non-empty, and
  returns either `{:ok, validated_struct}` (with typed field names as
  atoms) or `{:error, :missing_fields, [String.t()]}`.

  `validate_status_params/1` additionally checks that `"status"` is one of
  `"active"`, `"suspended"`, or `"revoked"` and returns
  `{:error, :invalid_status}` if not.

  Extracted from `ApiController` in 2026-04 to shrink the controller module
  without changing any request/response behavior. The validators are
  stateless and have no dependency on Phoenix or Connections — they're
  pure param shape checks.
  """

  alias PhoenixKitSync.Params

  @spec validate_register(map()) ::
          {:ok, %{sender_url: String.t(), connection_name: String.t(), auth_token: String.t()}}
          | {:error, :missing_fields, list(String.t())}
  def validate_register(params) do
    required_fields = ["sender_url", "connection_name", "auth_token"]

    with :ok <- require_all(params, required_fields) do
      {:ok,
       %{
         sender_url: params["sender_url"],
         connection_name: params["connection_name"],
         auth_token: params["auth_token"]
       }}
    end
  end

  @spec validate_delete(map()) ::
          {:ok, %{sender_url: String.t(), auth_token_hash: String.t()}}
          | {:error, :missing_fields, list(String.t())}
  def validate_delete(params) do
    with :ok <- require_all(params, ["sender_url", "auth_token_hash"]) do
      {:ok,
       %{
         sender_url: params["sender_url"],
         auth_token_hash: params["auth_token_hash"]
       }}
    end
  end

  @spec validate_get_status(map()) ::
          {:ok, %{receiver_url: String.t(), auth_token_hash: String.t()}}
          | {:error, :missing_fields, list(String.t())}
  def validate_get_status(params) do
    with :ok <- require_all(params, ["receiver_url", "auth_token_hash"]) do
      {:ok,
       %{
         receiver_url: params["receiver_url"],
         auth_token_hash: params["auth_token_hash"]
       }}
    end
  end

  @spec validate_status(map()) ::
          {:ok, %{sender_url: String.t(), auth_token_hash: String.t(), status: String.t()}}
          | {:error, :missing_fields, list(String.t())}
          | {:error, :invalid_status}
  def validate_status(params) do
    with :ok <- require_all(params, ["sender_url", "auth_token_hash", "status"]),
         :ok <- require_status_value(params["status"]) do
      {:ok,
       %{
         sender_url: params["sender_url"],
         auth_token_hash: params["auth_token_hash"],
         status: params["status"]
       }}
    end
  end

  @spec validate_list_tables(map()) ::
          {:ok, %{auth_token_hash: String.t()}}
          | {:error, :missing_fields, list(String.t())}
  def validate_list_tables(params) do
    with :ok <- require_all(params, ["auth_token_hash"]) do
      {:ok, %{auth_token_hash: params["auth_token_hash"]}}
    end
  end

  @spec validate_pull_data(map()) ::
          {:ok, map()} | {:error, :missing_fields, list(String.t())}
  def validate_pull_data(params) do
    with :ok <- require_all(params, ["auth_token_hash", "table_name"]) do
      {:ok,
       %{
         auth_token_hash: params["auth_token_hash"],
         table_name: params["table_name"],
         conflict_strategy: params["conflict_strategy"] || "skip"
       }}
    end
  end

  @spec validate_schema(map()) ::
          {:ok, %{auth_token_hash: String.t(), table_name: String.t()}}
          | {:error, :missing_fields, list(String.t())}
  def validate_schema(params) do
    with :ok <- require_all(params, ["auth_token_hash", "table_name"]) do
      {:ok,
       %{
         auth_token_hash: params["auth_token_hash"],
         table_name: params["table_name"]
       }}
    end
  end

  @spec validate_records(map()) ::
          {:ok, map()} | {:error, :missing_fields, list(String.t())}
  def validate_records(params) do
    with :ok <- require_all(params, ["auth_token_hash", "table_name"]) do
      {:ok,
       %{
         auth_token_hash: params["auth_token_hash"],
         table_name: params["table_name"],
         limit: Params.bounded_int(params["limit"], 10, 1, 100),
         offset: Params.bounded_int(params["offset"], 0, 0, Params.max_offset()),
         ids: params["ids"],
         id_start: params["id_start"],
         id_end: params["id_end"]
       }}
    end
  end

  @doc """
  Validates a PostgreSQL table identifier: must start with a letter or
  underscore and contain only alphanumerics and underscores. Mirrors
  `SchemaInspector.valid_identifier?/1` but is the entry-point guard the
  controller uses before attempting any introspection.
  """
  @spec valid_table_name?(any()) :: boolean()
  def valid_table_name?(name) when is_binary(name) do
    Regex.match?(~r/^[a-zA-Z_][a-zA-Z0-9_]*$/, name)
  end

  def valid_table_name?(_), do: false

  # ---------------------------------------------------------------------------
  # Shared helpers
  # ---------------------------------------------------------------------------

  defp require_all(params, fields) do
    case Enum.filter(fields, &(is_nil(params[&1]) or params[&1] == "")) do
      [] -> :ok
      missing -> {:error, :missing_fields, missing}
    end
  end

  defp require_status_value(status) when status in ["active", "suspended", "revoked"], do: :ok
  defp require_status_value(_), do: {:error, :invalid_status}
end
