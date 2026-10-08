defmodule PhoenixKitSync.ColumnInfo do
  @moduledoc """
  Struct representing a single database column's metadata.

  ## Fields

  - `name` - Column name
  - `type` - PostgreSQL data type (e.g., `"bigint"`, `"text"`, `"ARRAY"`)
  - `element_type` - For an array column, its elements' data type (e.g.,
    `"uuid"`, `"character varying"`); nil otherwise
  - `nullable` - Whether the column allows NULL values
  - `primary_key` - Whether the column is part of the primary key
  - `default` - Default value expression or nil
  - `max_length` - Maximum character length or nil
  - `precision` - Numeric precision or nil
  - `scale` - Numeric scale or nil
  """

  # Sibling of TableSchema — encoded into the schema-response payload
  # over the WebSocket protocol. Same Jason.Encoder requirement.
  @derive Jason.Encoder
  @enforce_keys [:name, :type]
  defstruct [
    :name,
    :type,
    :element_type,
    :default,
    :max_length,
    :precision,
    :scale,
    nullable: false,
    primary_key: false
  ]

  @type t :: %__MODULE__{
          name: String.t(),
          type: String.t(),
          element_type: String.t() | nil,
          nullable: boolean(),
          primary_key: boolean(),
          default: String.t() | nil,
          max_length: integer() | nil,
          precision: integer() | nil,
          scale: integer() | nil
        }
end
