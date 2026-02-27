defmodule Jido.Shell.Guardrails.Rule do
  @moduledoc """
  Behaviour for guardrail rules.
  """

  alias Jido.Shell.Guardrails.Violation

  @type context :: %{
          root: String.t()
        }

  @callback check(context()) :: :ok | [Violation.t()]
end
