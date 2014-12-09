defmodule Supervisorring do
  def global_sup_ref(sup_ref), do: :"#{sup_ref}.GlobalSup"
  def child_manager_ref(sup_ref), do: :"#{sup_ref}.ChildManager"
  def local_sup_ref(sup_ref), do: sup_ref

  defmodule GlobalSup do
    use Supervisor
    def start_link(sup_ref,module_args), do:
      :supervisor.start_link({:local,sup_ref|>Supervisorring.global_sup_ref},__MODULE__,{sup_ref,module_args})
    def init({sup_ref,{module,args}}) do
      {:ok,{strategy,specs}}=module.init(args)
      :gen_server.cast(Supervisorring.App.Sup.SuperSup,{:monitor,sup_ref|>Supervisorring.global_sup_ref})
      supervise([
        supervisor(GlobalSup.LocalSup,[sup_ref,strategy]),
        worker(GlobalSup.ChildManager,[sup_ref,specs,module])
      ], strategy: :one_for_all) #Nodes Workers are bounded to directory manager
    end
    defmodule LocalSup do
      use Supervisor
      def start_link(sup_ref,strategy), do: 
        :supervisor.start_link({:local,sup_ref|>Supervisorring.local_sup_ref},__MODULE__,strategy)
      def init(strategy), do: {:ok,{strategy,[]}}
    end
    defmodule ChildManager do
      use GenServer
      import Enum
      defmodule State, do: defstruct(sup_ref: nil, child_specs: [], callback: nil, ring: nil)
      defmodule RingListener do
        use GenEvent
        def handle_event(:new_ring,child_manager) do
          :gen_server.cast(child_manager,:sync_children)
          {:ok,child_manager}
        end
      end

      def start_link(sup_ref,specs,callback), do:
        :gen_server.start_link({:local,sup_ref|>Supervisorring.child_manager_ref},__MODULE__,{sup_ref,specs,callback},[])
      def init({sup_ref,child_specs,callback}) do
        :gen_event.add_sup_handler(Supervisorring.Events,RingListener,self)
        {:noreply,state}=handle_cast(:sync_children,%State{sup_ref: sup_ref,child_specs: child_specs,callback: callback})
        {:ok,state}
      end
      def handle_info({:gen_event_EXIT,_,_},_), do: 
        exit(:ring_listener_died)
      def handle_call({:get_node,id},_,state), do:
        {:reply,ConsistentHash.node_for_key(state.ring,{state.sup_ref,id}),state}

      # reliable execution is ensured by queueing executions on the same queue
      # which modify local children according to ring (on :sync_children message) so if
      # "node_for_key"==node then proc associated with id is running on the node
      def handle_cast({:onnode,id,sender,fun},state) do
        case ConsistentHash.node_for_key(state.ring,{state.sup_ref,id}) do
          n when n==node -> send sender, {:executed,fun.()}
          othernode -> :gen_server.cast({state.sup_ref|>Supervisorring.child_manager_ref,othernode},{:onnode,id,sender,fun})
        end
        {:noreply,state}
      end
      def handle_cast({:get_handler,childid,sender},%State{child_specs: specs}=state) do
        send sender, specs|>filter(&match?({:dyn_child_handler,_},&1))|>find(fn{_,h}->h.match(childid)end)
        {:noreply,state}
      end
      def handle_cast(:sync_children,%State{sup_ref: sup_ref,child_specs: specs,callback: callback}=state) do
        ring = :gen_event.call(NanoRing.Events,Supervisorring.App.Sup.SuperSup.NodesListener,:get_ring)
        cur_children = :supervisor.which_children(sup_ref|>Supervisorring.local_sup_ref) |> reduce(HashDict.new,fn {id,_,_,_}=e,dic->dic|>Dict.put(id,e) end)
        all_children = expand_specs(specs)|>reduce(HashDict.new,fn {id,_,_,_,_,_}=e,dic->dic|>Dict.put(id,e) end)
        ## the tricky point is here, take only child specs with an id which is associate with the current node in the ring
        remote_children_keys = all_children |> Dict.keys |> filter &(ConsistentHash.node_for_key(ring,{sup_ref,&1}) !== node)
        wanted_children = all_children |> Dict.drop remote_children_keys
                                             
        IO.puts "wanted children : #{inspect wanted_children}"
        ## kill all the local children which should not be in the node, get/start child on the correct node to migrate state if needed
        cur_children |> filter(fn {id,_}->not Dict.has_key?(wanted_children,id) end) |> each fn {id,{id,child,type,modules}}->
          new_node = ConsistentHash.node_for_key(ring,{sup_ref,id})
          if is_pid(child) do
            case :rpc.call(new_node,:supervisor,:start_child,[sup_ref|>Supervisorring.local_sup_ref,all_children|>Dict.get(id)]) do
              {:error,{:already_started,existingpid}}->callback.migrate({id,type,modules},child,existingpid)
              {:ok,newpid}->callback.migrate({id,type,modules},child,newpid)
              _ -> :nothingtodo
            end
            sup_ref |> Supervisorring.local_sup_ref |> :supervisor.terminate_child(id)
          end
          sup_ref |> Supervisorring.local_sup_ref |> :supervisor.delete_child(id)
        end
        wanted_children |> filter(fn {id,_}->not Dict.has_key?(cur_children,id) end) |> each fn {_,childspec}-> 
          :supervisor.start_child(sup_ref|>Supervisorring.local_sup_ref,childspec)
        end
        {:noreply,%{state|ring: ring}}
      end
      defp expand_specs(specs) do
        {spec_generators,child_specs} = specs |> partition(&match?({:dyn_child_handler,_},&1))
        concat(child_specs,spec_generators |> flat_map(fn {:dyn_child_handler,handler}->handler.get_all end))
      end
    end
  end

  defmacro __using__(_) do
    quote do
      @behaviour :dyn_child_handler
      @behaviour :supervisorring
      import Supervisor.Spec

      def migrate(_,_,_), do: :ok

      def match(_), do: true
      def get_all, do: []
      def add(_), do: :ok
      def del(_), do: :ok

      def dynamic, do: {:dyn_child_handler,__MODULE__}

      defoverridable [match: 1, get_all: 0, add: 1, del: 1, migrate: 3]
    end
  end

  def start_link(module, arg, name: name) when is_atom(name) do
    :supervisorring.start_link({:local, name}, module, arg)
  end

  defdelegate [find(supref,id),
               exec(supref,id,fun,timeout,retry), exec(supref,id,fun,timeout), exec(supref,id,fun),
               start_child(supref,spec),
               terminate_child(supref,id),
               delete_child(supref,id),
               restart_child(supref,id),
               which_children(supref),
               count_children(supref)], to: :supervisorring
end

defmodule :dyn_child_handler do
  use Behaviour
  defcallback get_all
  defcallback match(child_id::atom())
  defcallback add(child_spec :: term())
  defcallback del(child_id :: atom())
end

defmodule :supervisorring do
  use Behaviour
  import Supervisorring
  @doc "process migration function, called before deleting a pid when the ring change"
  defcallback migrate({id::atom(),type:: :worker|:supervisor, modules::[module()]|:dynamic},old_pid::pid(),new_pid::pid())
  @doc """
  supervisor standard callback, but with a new type of childspec to handle an
  external (global) source of child list (necessary for dynamic child starts,
  global process list must be maintained externally):
  standard child_spec : {id,startFunc,restart,shutdown,type,modules}
  new child_spec : {:dyn_child_handler,module::dyn_child_handler}
  works only with :permanent children, because a terminate state is restarted on ring migration
  """
  defcallback init(args::term())

  @doc "find node is fast but rely on local ring"
  def find(supref,id), do: :gen_server.call(supref|>child_manager_ref,{:get_node,id})
  @doc """
  exec() remotely queued execution to ensure reliability even if a node of the
  ring has just crashed... with nb_try retry if timeout is reached
  """
  def exec(supref,id,fun,timeout \\ 1000,retry \\ 3), do:
    try_exec(supref|>child_manager_ref,id,fun,timeout,retry)
  def try_exec(_,_,_,_,0), do: exit(:ring_unable_to_exec_fun)
  def try_exec(child_manager,id,fun,timeout,nb_try) do
    :gen_server.cast child_manager,{:onnode,id,self,fun}
    receive do {:executed,res} -> res after timeout -> try_exec(child_manager,id,fun,timeout,nb_try-1) end
  end

  @doc """
  start supervisorring process, which is a simple erlang supervisor, but the
  children are dynamically defined as the processes whose "id" is mapped to the
  current node in the ring. An event handler kills or starts children on ring
  change if necessary to maintain the proper process distribution.
  """
  def start_link({:local,name},module,args), do:
    Supervisorring.GlobalSup.start_link(name,{module,args})

  @doc """ 
  to maintain global process list related to a given {:child_spec_gen,fun} external child list specification
  """
  def start_child(supref,{id,_,_,_,_,_}=childspec) do
  case exec(supref,id,fn-> :supervisor.start_child(supref|>local_sup_ref,childspec) end) do
      {:ok,child}->:gen_server.cast(child_manager_ref(supref),{:get_handler,id,self})
        receive do
          {:dyn_child_handler,handler}-> {handler.add(childspec),child}
          _ -> {:error,{:cannot_match_handler,id}}
          after 10000 -> {:error,:child_server_timeout}
        end
      r -> r
    end
  end

  def terminate_child(supref,id) do
    exec(supref,id,fn->:supervisor.terminate_child(supref|>local_sup_ref,id) end)
  end

  @doc """ 
  to maintain global process list related to a given {:child_spec_gen,fun} external child list specification
  """
  def delete_child(supref,id) do
    case exec(supref,id,fn->:supervisor.delete_child(supref|>local_sup_ref,id) end) do
      :ok->:gen_server.cast(child_manager_ref(supref),{:get_handler,id,self})
        receive do
          {:dyn_child_handler,handler}-> handler.del(id)
          _ -> {:error,{:cannot_match_handler,id}}
          after 10000 -> {:error,:child_server_timeout}
        end
      r -> r
    end
  end

  def restart_child(supref,id) do
    exec(supref,id,fn->:supervisor.restart_child(supref|>local_sup_ref,id) end)
  end

  def which_children(supref) do
    {res,_}=:rpc.multicall(:gen_server.call(NanoRing,:get_up)|>Enum.to_list,:supervisor,:which_children,[supref|>local_sup_ref])
    res |> Enum.concat
  end

  def count_children(supref) do
    {res,_}=:rpc.multicall(:gen_server.call(NanoRing,:get_up)|>Enum.to_list,:supervisor,:count_children,[supref|>local_sup_ref])
    res |> Enum.reduce([],fn(statdict,acc)->acc|>Dict.merge(statdict,fn _,v1,v2->v1+v2 end) end)
  end
end

