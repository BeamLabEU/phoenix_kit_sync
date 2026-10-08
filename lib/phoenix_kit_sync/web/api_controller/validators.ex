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
         limit: parse_int(params["limit"], 10),
         offset: parse_int(params["offset"], 0),
         ids: params["ids"],
         id_start: params["id_start"],
         id_end: params["id_end"]
       }}
    end
  end

  @doc """
  Validates a PostgreSQL table identifier, the entry-point guard the
  controller uses before any introspection. Same rule as
  `SchemaInspector.valid_identifier?/1`, which it delegates to.
  """
  @spec valid_table_name?(any()) :: boolean()
  def valid_table_name?(name), do: PhoenixKitSync.SchemaInspector.valid_identifier?(name)

  @spec parse_int(any(), integer()) :: integer()
  def parse_int(nil, default), do: default
  def parse_int(val, _default) when is_integer(val), do: val

  def parse_int(val, default) when is_binary(val) do
    case Integer.parse(val) do
      {int, _} -> int
      :error -> default
    end
  end

  def parse_int(_, default), do: default

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
