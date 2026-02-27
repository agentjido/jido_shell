defmodule Jido.Shell.Guardrails.Violation do
  @moduledoc """
  Represents a single guardrail violation.
  """

  @enforce_keys [:rule, :message]
  defstruct [:rule, :message, :file]

  @type t :: %__MODULE__{
          rule: module(),
          message: String.t(),
          file: String.t() | nil
        }
end
