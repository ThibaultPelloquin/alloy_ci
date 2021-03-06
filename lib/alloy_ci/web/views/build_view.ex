defmodule AlloyCi.Web.BuildView do
  use AlloyCi.Web, :view
  import AlloyCi.Web.ProjectView, only: [ref_icon: 1, tags: 1]
  import AlloyCi.Builds, only: [clean_ref: 1, get_trace: 1]

  def artifact_for(conn, %{artifacts: %{}, artifact: artifact} = build)
      when not is_nil(artifact) do
    [
      content_tag :div, class: "h4" do
        [
          icon("file-archive-o", "fa-lg"),
          " ",
          link_to(conn, artifact, build)
        ]
      end,
      content_tag :p do
        "Expiry: #{from_now(artifact.expires_at)}"
      end,
      keep_button_link(conn, build)
    ]
  end

  def artifact_for(_, _) do
    content_tag(:p, "No artifacts were generated for this build.")
  end

  def build_actions(conn, build, icon_class \\ "")
  def build_actions(_, %{status: s}, _) when s in ~w(pending running created), do: ""

  def build_actions(conn, %{status: "manual", when: "manual"} = build, icon_class) do
    content_tag :span,
      class: "float-right",
      data: [toggle: "tooltip", placement: "bottom"],
      title: "Perform this build!" do
      link to: project_build_path(conn, :update, build.project_id, build.id),
           method: :put,
           class: "action-link" do
        icon("play", icon_class)
      end
    end
  end

  def build_actions(conn, build, icon_class) do
    content_tag :span,
      class: "float-right",
      data: [toggle: "tooltip", placement: "bottom"],
      title: "Restart this build" do
      link to: project_build_path(conn, :create, build.project_id, %{id: build.id}),
           method: :post,
           class: "action-link" do
        icon("refresh", icon_class)
      end
    end
  end

  def build_duration(%{finished_at: f, started_at: s}) when is_nil(f) or is_nil(s) do
    "Pending"
  end

  def build_duration(build) do
    (Timex.to_unix(build.finished_at) - Timex.to_unix(build.started_at))
    |> TimeConvert.to_compound()
  end

  def build_loading_icon("running"), do: icon("spinner", "fa-spin fa-2x")
  def build_loading_icon(_), do: ""

  def from_now(nil), do: "Never"
  def from_now(time), do: time |> Timex.from_now()

  def runner(nil), do: "Pending"
  def runner(id), do: "##{id}"

  defp keep_button_link(_, %{artifact: %{expires_at: nil}}), do: ""

  defp keep_button_link(conn, %{artifact: artifact} = build) do
    if Timex.after?(artifact.expires_at, Timex.now()) do
      content_tag :span do
        link(
          "Keep artifacts forever",
          to: project_build_keep_artifact_path(conn, :keep_artifact, build.project_id, build),
          method: :post,
          class: "btn btn-secondary m-t-1"
        )
      end
    else
      ""
    end
  end

  defp link_to(conn, %{expires_at: ex} = artifact, build) when not is_nil(ex) do
    if Timex.after?(ex, Timex.now()) do
      link(
        artifact.file[:file_name],
        to: project_build_artifact_path(conn, :artifact, build.project, build)
      )
    else
      artifact.file[:file_name]
    end
  end

  defp link_to(conn, artifact, build) do
    link(
      artifact.file[:file_name],
      to: project_build_artifact_path(conn, :artifact, build.project, build)
    )
  end
end
