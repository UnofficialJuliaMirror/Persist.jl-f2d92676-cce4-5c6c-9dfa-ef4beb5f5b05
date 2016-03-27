module Persist

# TODO: use ClusterManagers
# using ClusterManagers

import Base: serialize, deserialize, isready, wait, fetch
export serialize, deserialize, isready, wait, fetch

export JobManager, ProcessManager, PBSManager, SlurmManager
export JobStatus, job_empty, job_queued, job_running, job_done, job_failed
export status, jobinfo, cancel, getstdout, getstderr, cleanup
export persist, @persist, readmgr



"Sanitize a a file name; allow only Posix fully portable filenames"
function sanitize(str::AbstractString)
    # Only allow certain characters
    str = replace(str, r"[^-A-Za-z0-9._]", "")
    # Remove leading hyphens
    str = replace(str, r"^-*", "")
    # Disallow empty filenames
    @assert str != ""
    str
end

"Quote a string for use in Julia"
function juliaquote(str::AbstractString)
    return "\"$(escape_string(str))\""
end

"Quote a string for use as a shell argument"
function shellquote(str::AbstractString)
    buf = IOBuffer()
    inquote = false
    for ch in str
        if ch == '\''
            # Escape single quotes via a backslash, outside of single quotes
            if inquote
                write(buf, '\'')
                inquote = false
            end
            write(buf, "\\'")
        else
            # Escape all special characters via single quotes
            if !(isascii(ch) && isalnum(ch) || ch in "-./_'")
                if !inquote
                    write(buf, '\'')
                    inquote = true
                end
            end
            write(buf, ch)
        end
    end
    # Ensure the single quotes match
    if inquote
        write(buf, '\'')
        inquote = false
    end
    @assert !inquote
    # Ensure the result is not empty
    if buf.size == 0
        write(buf, "''")
    end
    @assert buf.size > 0
    takebuf_string(buf)
end

"Remove a directory tree, handling temporary failures gracefully"
function rmtree(path::AbstractString)
    try
        rm(path, recursive=true)
    catch
        # We cannot remove the file or directory. This can happen for
        # several benign reasons, e.g. on NFS file systems, or if a
        # process is using it as its current directory.
        # As a work-around, create a directory "Trash" and move the
        # job directory there.
        # Note: This does not work on Windows.
        # Create trash directory
        trashdir = "Trash"
        try mkdir(trashdir) end
        # Move file or directory to trash directory
        uuid = Base.Random.uuid4()
        file = basename(path)
        newname = "$file-$uuid"
        try
            mv(path, joinpath(trashdir, newname))
        catch e
            # Ignore the error on Windows, since there doesn't seem to
            # be a work-around
            @unix_only rethrow(e)
        end
        # Try to delete trash directory, including everything that was
        # previously moved there
        try rm(trashdir, recursive=true) end
    end
    nothing
end



"Directory for a job"
function jobdirname(jobname::AbstractString)
    "$(sanitize(jobname)).job"
end

"File name for serialized job"
function jobfilename(jobname::AbstractString)
    "$(sanitize(jobname)).bin"
end

"File name for serialized job result"
function resultfilename(jobname::AbstractString)
    "$(sanitize(jobname)).res"
end

"File name for job's stdout"
function outfilename(jobname::AbstractString)
    "$(sanitize(jobname)).out"
end

"File name for job's stderr"
function errfilename(jobname::AbstractString)
    "$(sanitize(jobname)).err"
end

"File name for serialize job manager"
function mgrfilename(jobname::AbstractString)
    "$(sanitize(jobname)).mgr"
end

"File name for shell script wrapper that starts the job"
function shellfilename(jobname::AbstractString)
    "$(sanitize(jobname)).sh"
end



"Abstract base class for all job managers"
abstract JobManager

"Job status codes"
@enum JobStatus job_empty job_queued job_running job_done job_failed



"`runjob` is called from the shell script to execute the job"
function runjob(jobfile::AbstractString, resultfile::AbstractString)
    # Delete any existing job results
    tmpfile = "$resultfile.tmp"
    try rm(resultfile) end
    try rm(tmpfile) end
    # Deserialize the job
    local job
    open(jobfile, "r") do f
        job = deserialize(f)
    end
    # Run the job
    result = job()
    # Serialize the result
    try
        open(tmpfile, "w") do f
            serialize(f, result)
        end
        mv(tmpfile, resultfile)
    finally
        try rm(tmpfile) end
    end
end



"Process job manager: A job manager based on Julia processes"
type ProcessManager <: JobManager
    jobname::AbstractString
    pid::Int32

    function ProcessManager(jobname::AbstractString)
        new(jobname, -1)
    end

    ProcessManager(::Base.SerializationState) = new()
end

function serialize(s::Base.SerializationState, mgr::ProcessManager)
    Base.Serializer.serialize_type(s, ProcessManager)
    serialize(s, mgr.jobname)
    serialize(s, mgr.pid)
end

function deserialize(s::Base.SerializationState, ::Type{ProcessManager})
    mgr = ProcessManager(s)
    mgr.jobname = deserialize(s)
    mgr.pid = deserialize(s)
    mgr
end

"File name holding job's pid (process id)"
function pidfilename(jobname::AbstractString)
    "$(sanitize(jobname)).pid"
end

"Submit a job"
function submit(job, mgr::ProcessManager; usempi::Bool=false, nprocs::Integer=0)
    @assert nprocs >= 0
    @assert status(mgr) == job_empty
    # Create job directory
    jobdir = jobdirname(mgr.jobname)
    jobdir = abspath(jobdir)
    try
        mkdir(jobdir)
    catch
        # There is another job with the same name
        error("Job directory \"$jobdir\"exists already")
    end
    # Serialize the Julia function
    jobfile = jobfilename(mgr.jobname)
    open(joinpath(jobdir, jobfile), "w") do f
        serialize(f, job)
    end
    # Create a wrapper script
    resultfile = resultfilename(mgr.jobname)
    outfile = outfilename(mgr.jobname)
    errfile = errfilename(mgr.jobname)
    shellfile = shellfilename(mgr.jobname)
    pidfile = pidfilename(mgr.jobname)
    open(joinpath(jobdir, shellfile), "w") do f
        shellcmd = AbstractString[]
        if usempi
            push!(shellcmd, "mpiexec")
            if nprocs>0
                push!(shellcmd, "-n", "$nprocs")
            end
        end
        append!(shellcmd, Base.julia_cmd().exec)
        if !usempi
            if nprocs>0
                push!(shellcmd, "-p", "$nprocs")
            end
        end
        juliacmd = "using Persist; Persist.runjob($(juliaquote(jobfile)), $(juliaquote(resultfile)))"
        push!(shellcmd, "-e", juliacmd)
        shellcmd = map(shellquote, shellcmd)
        push!(shellcmd, "</dev/null")
        push!(shellcmd, ">$(shellquote(outfile))")
        push!(shellcmd, "2>$(shellquote(errfile))")
        print(f, """
#! /bin/sh
# This is an auto-generated Julia script for the Persist package
echo \$\$ >$(shellquote(pidfile))
$(join(shellcmd, " "))
""")
    end
    # Pre-create output files
    open(joinpath(jobdir, outfile), "w") do f end
    open(joinpath(jobdir, errfile), "w") do f end
    open(joinpath(jobdir, pidfile), "w") do f end
    # Start the job in the job directory
    spawn(detach(setenv(`sh $shellfile`, dir=jobdir)))
    # Wait for the job to output its pid
    # TODO: We should get the pid from spwan, but I don't know how
    local buf
    while true
        buf = readall(joinpath(jobdir, pidfile))
        if endswith(buf, '\n') break end
        sleep(0.1)
    end
    mgr.pid = parse(Int, buf)
    info("Process id: $(mgr.pid)")
    # Serialize the manager
    mgrfile = mgrfilename(mgr.jobname)
    open(joinpath(jobdir, mgrfile), "w") do f
        serialize(f, mgr)
    end
    nothing
end

"Get job status code"
function status(mgr::ProcessManager)
    if mgr.pid < 0 return job_empty end
    # It seems that we can't check the process pid, since the process will
    # live too long -- this is probably a problem in detach
    # if success(pipeline(`ps -p $(mgr.pid)`, stdout=DevNull, stderr=DevNull))
    #     job_running
    # else
    #     job_done
    # end
    resultfile = joinpath(jobdirname(mgr.jobname), resultfilename(mgr.jobname))
    isfile(resultfile) && return job_done
    job_running
end

"Get job info string"
function jobinfo(mgr::ProcessManager)
    st = status(mgr)
    @assert st != job_empty
    if st == job_queued return "[job_queued]" end
    if st == job_running
        try
            return readall(`ps -f -p $(mgr.pid)`)
        end
        # `ps` failed; most likely because the process does not exist any more
    end
    "[job_done]"
end

"Cancel a job"
function cancel(mgr::ProcessManager; force::Bool=false)
    @assert status(mgr) != job_empty
    signum = force ? "SIGKILL" : "SIGTERM"
    run(pipeline(ignorestatus(`kill -$signum $(mgr.pid)`),
                 stdout=DevNull, stderr=DevNull))
    # TODO: The job may still be running, and we will never know.
    # TODO: Mark the job as failed (or interrupted?)
    nothing
end

"Check whether a job is done"
function isready(mgr::ProcessManager)
    return status(mgr) == job_done
end

"Wait until a job is done"
function wait(mgr::ProcessManager)
    @assert status(mgr) != job_empty
    while !(status(mgr) in (job_done, job_failed))
        sleep(1)
    end
    nothing
end

"Fetch job result"
function fetch(mgr::ProcessManager)
    @assert status(mgr) != job_empty
    wait(mgr)
    resultfile = joinpath(jobdirname(mgr.jobname), resultfilename(mgr.jobname))
    local result
    open(resultfile, "r") do f
        result = deserialize(f)
    end
    result
end

"Get stdout from a job"
function getstdout(mgr::ProcessManager)
    @assert status(mgr) != job_empty
    readall(joinpath(jobdirname(mgr.jobname), outfilename(mgr.jobname)))
end

"Get stderr from a job"
function getstderr(mgr::ProcessManager)
    @assert status(mgr) != job_empty
    readall(joinpath(jobdirname(mgr.jobname), errfilename(mgr.jobname)))
end

"Clean up after a job (delete all traces of the job, including its result)"
function cleanup(mgr::ProcessManager)
    @assert status(mgr) in (job_done, job_failed)
    rmtree(jobdirname(mgr.jobname))
    mgr.pid = -1
    nothing
end



"PBS job manager: A job manager using the PBS queuing system"
type PBSManager <: JobManager
    jobname::AbstractString
    jobid::AbstractString

    function PBSManager(jobname::AbstractString)
        new(jobname, "")
    end

    PBSManager(::Base.SerializationState) = new()
end

function serialize(s::Base.SerializationState, mgr::PBSManager)
    Base.Serializer.serialize_type(s, PBSManager)
    serialize(s, mgr.jobname)
    serialize(s, mgr.jobid)
end

function deserialize(s::Base.SerializationState, ::Type{PBSManager})
    mgr = PBSManager(s)
    mgr.jobname = deserialize(s)
    mgr.jobid = deserialize(s)
    mgr
end

"Submit a job"
function submit(job, mgr::PBSManager; usempi::Bool=false, nprocs::Integer=0)
    @assert nprocs >= 0
    @assert status(mgr) == job_empty
    # Create job directory
    jobdir = jobdirname(mgr.jobname)
    jobdir = abspath(jobdir)
    try
        mkdir(jobdir)
    catch
        # There is another job with the same name
        error("Job directory \"$jobdir\"exists already")
    end
    # Serialize the Julia function
    jobfile = jobfilename(mgr.jobname)
    open(joinpath(jobdir, jobfile), "w") do f
        serialize(f, job)
    end
    # Create a wrapper script
    resultfile = resultfilename(mgr.jobname)
    outfile = outfilename(mgr.jobname)
    errfile = errfilename(mgr.jobname)
    shellfile = shellfilename(mgr.jobname)
    open(joinpath(jobdir, shellfile), "w") do f
        shellcmd = AbstractString[]
        if usempi
            push!(shellcmd, "mpiexec")
            if nprocs>0
                push!(shellcmd, "-n", "$nprocs")
            end
        end
        append!(shellcmd, Base.julia_cmd().exec)
        if !usempi
            if nprocs>0
                push!(shellcmd, "-p", "$nprocs")
            end
        end
        juliacmd = "using Persist; Persist.runjob($(juliaquote(jobfile)), $(juliaquote(resultfile)))"
        push!(shellcmd, "-e", juliacmd)
        shellcmd = map(shellquote, shellcmd)
        push!(shellcmd, "</dev/null")
        push!(shellcmd, ">$(shellquote(outfile))")
        push!(shellcmd, "2>$(shellquote(errfile))")
        print(f, """
#! /bin/sh
# This is an auto-generated Julia script for the Persist package
hostname
$(join(shellcmd, " "))
""")
    end
    # Pre-create output files
    open(joinpath(jobdir, outfile), "w") do f end
    open(joinpath(jobdir, errfile), "w") do f end
    # Start the job in the job directory
    # TODO: Teach Julia how to use the nodes that PBS reserved
    buf = readall(setenv(`qsub -D $jobdir -N $(mgr.jobname) -l nodes=$nprocs $shellfile`,
                         dir=jobdir))
    m = match(r"([0-9]+)[.]", buf)
    mgr.jobid = m.captures[1]
    info("PBS job id: $(mgr.jobid)")
    # Serialize the manager
    mgrfile = mgrfilename(mgr.jobname)
    open(joinpath(jobdir, mgrfile), "w") do f
        serialize(f, mgr)
    end
    nothing
end

"Get job status code"
function status(mgr::PBSManager)
    if isempty(mgr.jobid) return job_empty end
    try
        buf = readall(`qstat -x $(mgr.jobid)`)
        state = chomp(buf)
        if contains(state, "<job_state>Q</job_state>")
            return job_queued
        elseif (contains(state, "<job_state>H</job_state>") ||
                contains(state, "<job_state>R</job_state>"))
            return job_running
        elseif contains(state, "<job_state>C</job_state>")
            return job_done
        else
            @assert false
        end
    end
    # PBS knows nothing about this job
    resultfile = joinpath(jobdirname(mgr.jobname), resultfilename(mgr.jobname))
    isfile(resultfile) && job_done
    job_failed
end

"Get job info string"
function jobinfo(mgr::PBSManager)
    st = status(mgr)
    @assert st != job_empty
    try
        return readall(`qstat $(mgr.jobid)`)
    end
    # PBS knows nothing about this job
    "[job_done]"
end

"Cancel a job"
function cancel(mgr::PBSManager; force::Bool=false)
    @assert status(mgr) != job_empty
    # TODO: Handle things differently for force=false and force=true
    run(`qdel $(mgr.jobid)`)
    nothing
end

"Check whether a job is done"
function isready(mgr::PBSManager)
    return status(mgr) == job_done
end

"Wait until a job is done"
function wait(mgr::PBSManager)
    @assert status(mgr) != job_empty
    while !(status(mgr) in (job_done, job_failed))
        sleep(1)
    end
    nothing
end

"Fetch job result"
function fetch(mgr::PBSManager)
    wait(mgr)
    resultfile = joinpath(jobdirname(mgr.jobname), resultfilename(mgr.jobname))
    local result
    open(resultfile, "r") do f
        result = deserialize(f)
    end
    result
end

"Get stdout from a job"
function getstdout(mgr::PBSManager)
    @assert status(mgr) != job_empty
    # TODO: Read stdout while job is running
    readall(joinpath(jobdirname(mgr.jobname), outfilename(mgr.jobname)))
end

"Get stderr from a job"
function getstderr(mgr::PBSManager)
    @assert status(mgr) != job_empty
    # TODO: Read stdout while job is running
    readall(joinpath(jobdirname(mgr.jobname), errfilename(mgr.jobname)))
end

"Clean up after a job (delete all traces of the job, including its result)"
function cleanup(mgr::PBSManager)
    @assert status(mgr) in (job_done, job_failed)
    rmtree(jobdirname(mgr.jobname))
    mgr.jobid = ""
    nothing
end



"Slurm job manager: A job manager using the Slurm queuing system"
type SlurmManager <: JobManager
    jobname::AbstractString
    jobid::AbstractString

    function SlurmManager(jobname::AbstractString)
        new(jobname, "")
    end

    SlurmManager(::Base.SerializationState) = new()
end

function serialize(s::Base.SerializationState, mgr::SlurmManager)
    Base.Serializer.serialize_type(s, SlurmManager)
    serialize(s, mgr.jobname)
    serialize(s, mgr.jobid)
end

function deserialize(s::Base.SerializationState, ::Type{SlurmManager})
    mgr = SlurmManager(s)
    mgr.jobname = deserialize(s)
    mgr.jobid = deserialize(s)
    mgr
end

"Submit a job"
function submit(job, mgr::SlurmManager; usempi::Bool=false, nprocs::Integer=0)
    @assert nprocs >= 0
    @assert status(mgr) == job_empty
    # Create job directory
    jobdir = jobdirname(mgr.jobname)
    jobdir = abspath(jobdir)
    try
        mkdir(jobdir)
    catch
        # There is another job with the same name
        error("Job directory \"$jobdir\"exists already")
    end
    # Serialize the Julia function
    jobfile = jobfilename(mgr.jobname)
    open(joinpath(jobdir, jobfile), "w") do f
        serialize(f, job)
    end
    # Create a wrapper script
    resultfile = resultfilename(mgr.jobname)
    outfile = outfilename(mgr.jobname)
    errfile = errfilename(mgr.jobname)
    shellfile = shellfilename(mgr.jobname)
    open(joinpath(jobdir, shellfile), "w") do f
        shellcmd = AbstractString[]
        if usempi
            push!(shellcmd, "mpiexec")
            if nprocs>0
                push!(shellcmd, "-n", "$nprocs")
            end
        end
        append!(shellcmd, Base.julia_cmd().exec)
        if !usempi
            if nprocs>0
                push!(shellcmd, "-p", "$nprocs")
            end
        end
        juliacmd = "using Persist; Persist.runjob($(juliaquote(jobfile)), $(juliaquote(resultfile)))"
        push!(shellcmd, "-e", juliacmd)
        shellcmd = map(shellquote, shellcmd)
        push!(shellcmd, "</dev/null")
        push!(shellcmd, ">$(shellquote(outfile))")
        push!(shellcmd, "2>$(shellquote(errfile))")
        print(f, """
#! /bin/sh
# This is an auto-generated Julia script for the Persist package
hostname
$(join(shellcmd, " "))
""")
    end
    # Pre-create output files
    open(joinpath(jobdir, outfile), "w") do f end
    open(joinpath(jobdir, errfile), "w") do f end
    # Start the job in the job directory
    # TODO: Teach Julia how to use the nodes that Slurm reserved
    buf = readall(setenv(`sbatch -D $jobdir -J $(mgr.jobname) -n $nprocs $shellfile`,
                         dir=jobdir))
    m = match(r"Submitted batch job ([0-9]+)", buf)
    mgr.jobid = m.captures[1]
    info("Slurm job id: $(mgr.jobid)")
    # Serialize the manager
    mgrfile = mgrfilename(mgr.jobname)
    open(joinpath(jobdir, mgrfile), "w") do f
        serialize(f, mgr)
    end
    nothing
end

"Get job status code"
function status(mgr::SlurmManager)
    if isempty(mgr.jobid) return job_empty end
    try
        buf = readall(`squeue -h -j $(mgr.jobid) -o '%t'`)
        state = chomp(buf)
        if state in ["CF", "PD"]
            return job_queued
        elseif state in ["CG", "R", "S"]
            return job_running
        elseif state in ["CA", "CD", "F", "NF", "PR", "TO"]
            return job_done
        else
            @assert false
        end
    end
    # Slurm knows nothing about this job
    resultfile = joinpath(jobdirname(mgr.jobname), resultfilename(mgr.jobname))
    isfile(resultfile) && job_done
    job_failed
end

"Get job info string"
function jobinfo(mgr::SlurmManager)
    st = status(mgr)
    @assert st != job_empty
    try
        return readall(`squeue -j $(mgr.jobid)`)
    end
    # Slurm knows nothing about this job
    "[job_done]"
end

"Cancel a job"
function cancel(mgr::SlurmManager; force::Bool=false)
    @assert status(mgr) != job_empty
    # TODO: Handle things differently for force=false and force=true
    run(`scancel -j $(mgr.jobid)`)
    nothing
end

"Check whether a job is done"
function isready(mgr::SlurmManager)
    return status(mgr) == job_done
end

"Wait until a job is done"
function wait(mgr::SlurmManager)
    @assert status(mgr) != job_empty
    while !(status(mgr) in (job_done, job_failed))
        sleep(1)
    end
    nothing
end

"Fetch job result"
function fetch(mgr::SlurmManager)
    wait(mgr)
    resultfile = joinpath(jobdirname(mgr.jobname), resultfilename(mgr.jobname))
    local result
    open(resultfile, "r") do f
        result = deserialize(f)
    end
    result
end

"Get stdout from a job"
function getstdout(mgr::SlurmManager)
    @assert status(mgr) != job_empty
    # TODO: Read stdout while job is running
    readall(joinpath(jobdirname(mgr.jobname), outfilename(mgr.jobname)))
end

"Get stderr from a job"
function getstderr(mgr::SlurmManager)
    @assert status(mgr) != job_empty
    # TODO: Read stdout while job is running
    readall(joinpath(jobdirname(mgr.jobname), errfilename(mgr.jobname)))
end

"Clean up after a job (delete all traces of the job, including its result)"
function cleanup(mgr::SlurmManager)
    @assert status(mgr) in (job_done, job_failed)
    rmtree(jobdirname(mgr.jobname))
    mgr.jobid = ""
    nothing
end



"Start a job"
function persist{JM<:JobManager}(job, jobname::AbstractString, ::Type{JM};
                                 usempi::Bool=false, nprocs::Integer=0)
    mgr = JM(jobname)
    submit(job, mgr, usempi=usempi, nprocs=nprocs)
    mgr::JM
end

"Start a job"
macro persist(jobname, mgrtype, expr)
    expr = Base.localize_vars(:(()->$expr), false)
    :(persist($(esc(expr)), $(esc(jobname)), $(esc(mgrtype))))
    # quote
    #     expr = ()->eval(Main, $(Expr(:quote, expr)))
    #     persist(expr, $(esc(jobname)), $(esc(mgrtype)))
    # end
end

"Read job manager from file"
function readmgr(jobname::AbstractString)
    mgrfile = joinpath(jobdirname(jobname), mgrfilename(jobname))
    local mgr
    open(mgrfile, "r") do f
        mgr = deserialize(f)
    end
    mgr::JobManager
end

end # module
