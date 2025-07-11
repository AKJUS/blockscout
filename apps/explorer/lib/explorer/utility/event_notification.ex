defmodule Explorer.Utility.EventNotification do
  @moduledoc """
  An auxiliary schema for sending postgres notifications.
  """

  use Explorer.Schema

  typed_schema "event_notifications" do
    field(:data, :string)

    timestamps()
  end

  @doc false
  def changeset(event_notification, params \\ %{}) do
    cast(event_notification, params, [:data])
  end

  def new_changeset(data) do
    changeset(%__MODULE__{}, %{data: data})
  end
end
