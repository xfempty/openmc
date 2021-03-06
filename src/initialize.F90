module initialize

  use, intrinsic :: ISO_C_BINDING

#ifdef _OPENMP
  use omp_lib
#endif

  use bank_header,     only: Bank
  use constants
  use input_xml,       only: read_input_xml
  use message_passing
  use random_lcg,      only: openmc_set_seed
  use settings
  use string,          only: ends_with, to_f_string
  use timer_header

  implicit none

  type(C_PTR), bind(C) :: openmc_path_input
  type(C_PTR), bind(C) :: openmc_path_statepoint
  type(C_PTR), bind(C) :: openmc_path_sourcepoint
  type(C_PTR), bind(C) :: openmc_path_particle_restart

contains

!===============================================================================
! OPENMC_INIT takes care of all initialization tasks, i.e. reading
! from command line, reading xml input files, initializing random
! number seeds, reading cross sections, initializing starting source,
! setting up timers, etc.
!===============================================================================

  function openmc_init_f(intracomm) result(err) bind(C)
    integer, intent(in), optional :: intracomm  ! MPI intracommunicator
    integer(C_INT) :: err

#ifdef _OPENMP
    character(MAX_WORD_LEN) :: envvar
#endif

    ! Copy the communicator to a new variable. This is done to avoid changing
    ! the signature of this subroutine. If MPI is being used but no communicator
    ! was passed, assume MPI_COMM_WORLD.
#ifdef OPENMC_MPI
#ifdef OPENMC_MPIF08
    type(MPI_Comm), intent(in) :: comm     ! MPI intracommunicator
    if (present(intracomm)) then
      comm % MPI_VAL = intracomm
    else
      comm = MPI_COMM_WORLD
    end if
#else
    integer :: comm
    if (present(intracomm)) then
      comm = intracomm
    else
      comm = MPI_COMM_WORLD
    end if
#endif
#endif

    ! Start total and initialization timer
    call time_total%start()
    call time_initialize%start()

#ifdef OPENMC_MPI
    ! Setup MPI
    call initialize_mpi(comm)
#endif

#ifdef _OPENMP
    ! Change schedule of main parallel-do loop if OMP_SCHEDULE is set
    call get_environment_variable("OMP_SCHEDULE", envvar)
    if (len_trim(envvar) == 0) then
      call omp_set_schedule(omp_sched_static, 0)
    end if
#endif

    ! Read command line arguments
    call read_command_line()

    ! Initialize random number generator -- if the user specifies a seed, it
    ! will be re-initialized later
    call openmc_set_seed(DEFAULT_SEED)

    ! Read XML input files
    call read_input_xml()

    ! Check for particle restart run
    if (particle_restart_run) run_mode = MODE_PARTICLE

    ! Stop initialization timer
    call time_initialize%stop()

    err = 0
  end function openmc_init_f

#ifdef OPENMC_MPI
!===============================================================================
! INITIALIZE_MPI starts up the Message Passing Interface (MPI) and determines
! the number of processors the problem is being run with as well as the rank of
! each processor.
!===============================================================================

  subroutine initialize_mpi(intracomm)
#ifdef OPENMC_MPIF08
    type(MPI_Comm), intent(in) :: intracomm  ! MPI intracommunicator
#else
    integer, intent(in) :: intracomm         ! MPI intracommunicator
#endif

    integer                   :: mpi_err          ! MPI error code
    integer                   :: bank_blocks(5)   ! Count for each datatype
#ifdef OPENMC_MPIF08
    type(MPI_Datatype)        :: bank_types(5)
#else
    integer                   :: bank_types(5)    ! Datatypes
#endif
    integer(MPI_ADDRESS_KIND) :: bank_disp(5)     ! Displacements
    type(Bank) :: b

    ! Indicate that MPI is turned on
    mpi_enabled = .true.
    mpi_intracomm = intracomm

    ! ==========================================================================
    ! CREATE MPI_BANK TYPE

    ! Determine displacements for MPI_BANK type
    call MPI_GET_ADDRESS(b % wgt,           bank_disp(1), mpi_err)
    call MPI_GET_ADDRESS(b % xyz,           bank_disp(2), mpi_err)
    call MPI_GET_ADDRESS(b % uvw,           bank_disp(3), mpi_err)
    call MPI_GET_ADDRESS(b % E,             bank_disp(4), mpi_err)
    call MPI_GET_ADDRESS(b % delayed_group, bank_disp(5), mpi_err)

    ! Adjust displacements
    bank_disp = bank_disp - bank_disp(1)

    ! Define MPI_BANK for fission sites
    bank_blocks = (/ 1, 3, 3, 1, 1 /)
    bank_types = (/ MPI_REAL8, MPI_REAL8, MPI_REAL8, MPI_REAL8, MPI_INTEGER /)
    call MPI_TYPE_CREATE_STRUCT(5, bank_blocks, bank_disp, &
         bank_types, MPI_BANK, mpi_err)
    call MPI_TYPE_COMMIT(MPI_BANK, mpi_err)

  end subroutine initialize_mpi
#endif

!===============================================================================
! READ_COMMAND_LINE reads all parameters from the command line
!===============================================================================

  subroutine read_command_line()
    ! Arguments were already read on C++ side (initialize.cpp). Here we just
    ! convert the C-style strings to Fortran style

    character(kind=C_CHAR), pointer :: string(:)
    interface
      function is_null(ptr) result(x) bind(C)
        import C_PTR, C_BOOL
        type(C_PTR), value :: ptr
        logical(C_BOOL) :: x
      end function is_null
    end interface

    if (.not. is_null(openmc_path_input)) then
      call c_f_pointer(openmc_path_input, string, [255])
      path_input = to_f_string(string)
    else
      path_input = ''
    end if
    if (.not. is_null(openmc_path_statepoint)) then
      call c_f_pointer(openmc_path_statepoint, string, [255])
      path_state_point = to_f_string(string)
    end if
    if (.not. is_null(openmc_path_sourcepoint)) then
      call c_f_pointer(openmc_path_sourcepoint, string, [255])
      path_source_point = to_f_string(string)
    end if
    if (.not. is_null(openmc_path_particle_restart)) then
      call c_f_pointer(openmc_path_particle_restart, string, [255])
      path_particle_restart = to_f_string(string)
    end if

    ! Add slash at end of directory if it isn't there
    if (len_trim(path_input) > 0 .and. .not. ends_with(path_input, "/")) then
      path_input = trim(path_input) // "/"
    end if
  end subroutine read_command_line

end module initialize
