defmodule AlloyCi.Pipelines do
  @moduledoc """
  The boundary for the Pipelines system.
  """
  import Ecto.Query, warn: false

  alias AlloyCi.{
    Builds,
    Notifications,
    Pipeline,
    Projects,
    Queuer,
    Repo,
    User,
    Web.PipelinesChannel,
    Workers.CreateBuildsWorker
  }

  @github_api Application.get_env(:alloy_ci, :github_api)

  @spec cancel(Pipeline.t()) :: {:error, any()} | {:ok, Pipeline.t()}
  def cancel(pipeline) do
    with {:ok, pipeline} <- update_pipeline(pipeline, %{status: "cancelled"}) do
      query =
        from(
          b in "builds",
          where: b.pipeline_id == ^pipeline.id and b.status in ~w(created pending running),
          update: [set: [status: "cancelled"]]
        )

      case Repo.update_all(query, []) do
        {_, nil} ->
          @github_api.notify_cancelled!(pipeline.project, pipeline)
          {:ok, pipeline}

        _ ->
          {:error, nil}
      end
    end
  end

  @spec create_pipeline(Pipeline.t(), map()) :: any()
  def create_pipeline(pipeline, params) do
    pipeline
    |> Pipeline.changeset(params)
    |> Repo.insert()
  end

  @spec delete_where([{:project_id, any()}, ...]) :: :error | :ok
  def delete_where(project_id: id) do
    query =
      Pipeline
      |> where(project_id: ^id)

    case Repo.delete_all(query) do
      {_, nil} -> Builds.delete_where(project_id: id)
      _ -> :error
    end
  end

  @spec duplicate(Pipeline.t()) :: {:error, any()} | {:ok, Pipeline.t()}
  def duplicate(pipeline) do
    with {:ok, clone} <- clone(pipeline) do
      Queuer.push(CreateBuildsWorker, clone.id)
      @github_api.notify_pending!(pipeline.project, pipeline)
      {:ok, clone}
    end
  end

  @spec failed!(Pipeline.t()) :: {:error, any()} | {:ok, Pipeline.t()}
  def failed!(pipeline) do
    pipeline = pipeline |> Repo.preload(:project)
    @github_api.notify_failure!(pipeline.project, pipeline)
    finished_at = Timex.now()
    duration = Timex.diff(finished_at, Timex.to_datetime(pipeline.started_at, :utc), :seconds)

    unless pipeline.notified do
      with {:ok, _} <- update_pipeline(pipeline, %{notified: true}) do
        Notifications.send(pipeline, pipeline.project, "pipeline_failed")
      end
    end

    update_pipeline(pipeline, %{
      status: "failed",
      duration: duration,
      finished_at: finished_at
    })
  end

  @spec for_project(any()) :: [Pipeline.t()]
  def for_project(project_id) do
    Pipeline
    |> where(project_id: ^project_id)
    |> where([p], p.status == "pending" or p.status == "running")
    |> order_by(asc: :inserted_at)
    |> Repo.all()
  end

  @spec for_project_and_user(any(), any(), any()) :: false | nil | Pipeline.t()
  def for_project_and_user(id, project_id, user) do
    with true <- Projects.can_access?(project_id, user) do
      Pipeline
      |> where(project_id: ^project_id)
      |> Repo.get(id)
      |> Repo.preload(:project)
    end
  end

  @spec get(any()) :: Pipeline.t()
  def get(id), do: Pipeline |> Repo.get(id)

  @spec get_pipeline(any(), any(), User.t()) :: false | nil | Pipeline.t()
  def get_pipeline(id, project_id, user) do
    with true <- Projects.can_manage?(project_id, user) do
      Pipeline
      |> where(project_id: ^project_id)
      |> Repo.get(id)
      |> Repo.preload(:project)
    end
  end

  @spec get_with_project(any()) :: Pipeline.t()
  def get_with_project(id) do
    id
    |> get()
    |> Repo.preload(:project)
  end

  @spec has_artifacts?(Pipeline.t()) :: boolean()
  def has_artifacts?(pipeline) do
    query =
      from(
        b in "builds",
        where: b.pipeline_id == ^pipeline.id and not is_nil(b.artifacts),
        select: count(b.id)
      )

    case Repo.one(query) do
      0 ->
        false

      _ ->
        true
    end
  end

  @spec paginated(any(), map()) :: {[Pipeline.t()], Kerosene.t()}
  def paginated(project_id, params) do
    Pipeline
    |> where(project_id: ^project_id)
    |> order_by(desc: :inserted_at)
    |> Repo.paginate(params)
  end

  @spec run!(Pipeline.t()) :: nil | {:error, any()} | {:ok, Pipeline.t()}
  def run!(pipeline) do
    if pipeline.status == "pending" do
      update_pipeline(pipeline, %{status: "running", started_at: Timex.now()})
    end
  end

  @spec success!(pos_integer()) :: {:error, nil} | {:ok, Pipeline.t()}
  def success!(pipeline_id) do
    pipeline =
      pipeline_id
      |> get()
      |> Repo.preload([:builds, :project])

    build_stats = builds_by_status(pipeline_id)
    total_builds = Enum.count(pipeline.builds)

    cond do
      build_stats[:failed] > 0 || pipeline.status == "failed" ->
        failed!(pipeline)

      build_stats[:successful] + build_stats[:allowed_failures] + build_stats[:on_failure] ==
          total_builds ->
        @github_api.notify_success!(pipeline.project, pipeline)
        finished_at = Timex.now()
        duration = Timex.diff(finished_at, Timex.to_datetime(pipeline.started_at, :utc), :seconds)

        with {:ok, pipeline} <-
               update_pipeline(pipeline, %{
                 status: "success",
                 duration: duration,
                 finished_at: finished_at
               }) do
          Notifications.send(pipeline, pipeline.project, "pipeline_succeeded")
          {:ok, pipeline}
        end

      true ->
        {:error, nil}
    end
  end

  @spec update_pipeline(Pipeline.t(), map()) :: {:error, any()} | {:ok, Pipeline.t()}
  def update_pipeline(%Pipeline{} = pipeline, params) do
    with {:ok, pipeline} <-
           pipeline
           |> Pipeline.changeset(params)
           |> Repo.update() do
      PipelinesChannel.update_status(pipeline |> Repo.preload(:project))
      {:ok, pipeline}
    end
  end

  @spec update_status(pos_integer()) :: {:error, any()} | {:ok, Pipeline.t() | nil}
  def update_status(pipeline_id) do
    pipeline = get(pipeline_id)

    query =
      from(
        b in "builds",
        where:
          b.pipeline_id == ^pipeline_id and b.status in ~w(pending running success failed skipped),
        order_by: [desc: b.updated_at],
        limit: 1,
        select: %{status: b.status, allow_failure: b.allow_failure}
      )

    last_status = Repo.one(query) || %{status: "skipped", allow_failure: false}

    case last_status do
      %{status: "success"} -> success!(pipeline_id)
      %{status: "failed", allow_failure: false} -> failed!(pipeline)
      %{status: "skipped"} -> update_pipeline(pipeline, %{status: "running"})
      %{status: "running"} -> update_pipeline(pipeline, %{status: "running"})
      _ -> {:ok, nil}
    end
  end

  ###################
  # Private functions
  ###################
  defp builds_by_status(pipeline_id) do
    failed_builds =
      from(
        b in "builds",
        where:
          b.pipeline_id == ^pipeline_id and b.status == "failed" and b.allow_failure == false,
        select: count(b.id)
      )
      |> Repo.one()

    successful_builds =
      from(
        b in "builds",
        where: b.pipeline_id == ^pipeline_id and b.status == "success",
        select: count(b.id)
      )
      |> Repo.one()

    allowed_failures =
      from(
        b in "builds",
        where: b.pipeline_id == ^pipeline_id and b.status == "failed" and b.allow_failure == true,
        select: count(b.id)
      )
      |> Repo.one()

    on_failures =
      from(
        b in "builds",
        where: b.pipeline_id == ^pipeline_id and b.status == "created" and b.when == "on_failure",
        select: count(b.id)
      )
      |> Repo.one()

    %{
      failed: failed_builds,
      successful: successful_builds,
      allowed_failures: allowed_failures,
      on_failure: on_failures
    }
  end

  defp clone(pipeline) do
    params =
      pipeline
      |> Map.drop([
        :__meta__,
        :__struct__,
        :id,
        :inserted_at,
        :updated_at,
        :builds,
        :notified,
        :project,
        :status,
        :duration
      ])

    %Pipeline{}
    |> Pipeline.changeset(params)
    |> Repo.insert()
  end
end
