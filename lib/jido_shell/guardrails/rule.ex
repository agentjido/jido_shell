defmodule Jido.Shell.Guardrails.Rule do
  @moduledoc """
  Behaviour for guardrail rules.
  """

  alias Jido.Shell.Guardrails

  @callback check(project_root :: String.t()) :: :ok | [Guardrails.violation()]
end
