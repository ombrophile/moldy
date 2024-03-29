!!========================================================================
!!
!! MOLDY - Short Range Molecular Dynamics
!! Copyright (C) 2009 G.J.Ackland, K.D'Mellow, University of Edinburgh.
!! Cite as: Computer Physics Communications Volume 182, Issue 12, December 2011, Pages 2587-2604 
!!
!! This program is free software; you can redistribute it and/or modify
!! it under the terms of the GNU General Public License as published by
!! the Free Software Foundation; either version 2 of the License, or
!! (at your option) any later version.
!!
!! This program is distributed in the hope that it will be useful,
!! but WITHOUT ANY WARRANTY; without even the implied warranty of
!! MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
!! GNU General Public License for more details.
!!
!! You should have received a copy of the GNU General Public License
!! along with this program; if not, write to the Free Software
!! Foundation, Inc., 59 Temple Place, Suite 330, Boston, MA 02111-1307 USA
!!
!! You can contact the authors by email on g.j.ackland@ed.ac.uk
!! or by writing to Prof. GJ Ackland, School of Physics, JCMB,
!! University of Edinburgh, Edinburgh, EH9 3JZ, UK.
!!
!!========================================================================

!---------------------------------------------------------------------
!
!  dynamics_m.F90
!
!  MOLDY Dynamics module (dynamics_m)
!
!  Contains Predictor-Corrector routines, PREDIC and CORREC.
!  Contains VELOCITY-VERLET routine.
!  Contains FORCE routine and forces data.
!
!---------------------------------------------------------------------

#include "debug.f90"

module dynamics_m

  !! standard module dependencies
  use constants_m
  use params_m
  use utilityfns_m

  !! functional dependencies of interest
  use particles_m
  use potential_m
  use system_m
  use thermostat_m
  use parrinellorahman_m
  use neighbourlist_m

!$  !! extended functional dependencies for compilation with OpenMP
!$  !!OpenMP reqd
!$  use omp_lib
!$  use linkcell_m

!$ use timers_m

  implicit none

  private


  !! Public Interfaces
  public :: init_dynamics_m, cleanup_dynamics_m
  public :: force
  public :: energy_calc
  public :: update_neighbourlist
  public :: rhoset  
  public :: write_energy_forces_stress
  public :: write_stress
  public :: update_therm_avs
  public :: write_atomic_stress
   public :: energy_pair_emb
  

  !! public module data
  real(kind_wp), allocatable, public :: fx(:),fy(:),fz(:) !< forces are public
  real(kind_wp), allocatable, public :: x1_dt2(:), y1_dt2(:), z1_dt2(:) !< verlet half-step
 
  !! private module data
  
  type(simparameters), save :: simparam  !< module local copy of simulation parameters
!!  to Parinelloraman  real(kind_wp) :: tp(nmat,nmat)   !< module local copy of temporary stress/force
  integer :: istat                  !< allocation status

!$  !! OpenMP reqd (locks on the link cells)
!$  integer(kind=omp_lock_kind), allocatable :: lc_lock(:)  !< locks
!$  integer :: nlocks                     !< number of locks


contains
  !---------------------------------------------------------------------
  !
  ! module initialisation and cleanup
  !
  !---------------------------------------------------------------------
  subroutine init_dynamics_m
!$    integer :: i
    simparam=get_params()
!$  !! OpenMP reqd (allocate and initialise link-cell locks)
!$  nlocks=simparam%nlcx*simparam%nlcy*simparam%nlcz
!$  allocate(lc_lock(nlocks),stat=istat) 
!$  do i=1,nlocks
!$    call omp_init_lock(lc_lock(i))
!$  end do
    allocate(fx(simparam%nm),fy(simparam%nm),fz(simparam%nm),stat=istat) 
    allocate(x1_dt2(simparam%nm), y1_dt2(simparam%nm), z1_dt2(simparam%nm),stat=istat)
    if(istat.ne.0)stop 'ALLOCATION ERROR (init_dynamics_m) - Possibly out of memory.'
  end subroutine init_dynamics_m
  subroutine cleanup_dynamics_m
!$    integer :: i
!$  !! OpenMP reqd (destroy and deallocate locks)
!$  do i=1,nlocks
!$    call omp_destroy_lock(lc_lock(i))
!$  end do
!$  deallocate(lc_lock)
    deallocate(FX,FY,FZ)
    deallocate(x1_dt2,y1_dt2,z1_dt2)
    deallocate(stressx,stressy,stressz)
  end subroutine cleanup_dynamics_m


  !---------------------------------------------------------------------
  !
  ! subroutine force
  !
  ! computes forces on the particles
  !
  !---------------------------------------------------------------------
  subroutine force
    
    integer :: i, j, k
    integer :: nlist_ji
    real(kind_wp) :: cx, cy, cz
    real(kind_wp) :: dxminu, dyminu, dzminu
    real(kind_wp) :: dxplus, dyplus, dzplus
    real(kind_wp) :: dx, dy, dz
    real(kind_wp) :: ddfx, ddfy, ddfz
    real(kind_wp) :: fcp, fp, fpp
    real(kind_wp) :: r, rsq, pp, r_recip
    real(kind_wp) :: rxij, ryij, rzij !< spatial separation components
    real(kind_wp), parameter :: point5=0.5d0
    real(kind_wp) :: fxi, fyi, fzi !< ith particle force accumulator (in particleloop)

!$  !!OpenMP reqd (local declarations)
!$  integer :: neighlc             !< link cell index of the current neighbour
#if DEBUG_OMP_LOCKS
!$  integer :: num_locks = 0       !< Keep track of number of lock operations
#endif
#if DEBUG_OMP_TIMING
!$  integer     :: thread_num      !< The current thread's id
!$  real        :: start_time      !< Start times array for threads
#endif

    !! update module copy of simulation parameters
    simparam=get_params()

#if DEBUG_OMP_LOCKS
!$  num_locks = 0
#endif    

    !! initialise variables
    ke=0.0d0
    tp(:,:)=0.0d0
    tg(:,:)=0.0d0
    
    stressx(:) = 0.0
    stressy(:) = 0.0
    stressz(:) = 0.0
    
     !! initialise forces
    do i=1,simparam%nm
       fx(i)=0.0!!pr term here
       fy(i)=0.0
       fz(i)=0.0
    end do
    
    !! compute metric tensor
    call pr_get_metric_tensor
   
    !! increment neighbour list update counter and update if necessary
    simparam%ntc = simparam%ntc + 1

    call set_params(simparam)

    if(simparam%ntc.eq.1) then
       call update_neighbourlist
    end if

    IF (simparam%ntc.eq.simparam%ntcm) then
       simparam%ntc = 0
       call set_params(simparam)
    end if
    
    !! set rho(i) and related quantities required for the finnis-sinclair potential
    call rhoset(phi,rho)
     
    call embed(pe)    
    
    do i=1,nmat
       do k=1,nmat
          do j=1,nmat
             tg(i,j)=tg(i,j)+b0(k,i)*b0(k,j)
          end do
       end do
    end do

!$OMP PARALLEL PRIVATE(neighlc, i, j, fxi, fyi, fzi, nlist_ji, dx, dy, dz, r, pp, fpp, fcp, fp,&
!$OMP rxij, ryij, rzij, ddfx, ddfy, ddfz, r_recip), &
#if DEBUG_OMP_TIMING
!$OMP PRIVATE( thread_num, start_time ), &
#endif
!$OMP DEFAULT(NONE), &
!$OMP SHARED( simparam, numn, nlist, x0, y0, z0, atomic_number, atomic_mass, dafrho, b0, ic, lc_lock,&
!$OMP fx, fy, fz, tc, stressx, stressy, stressz ), &
#if DEBUG_OMP_LOCKS
!$OMP REDUCTION(+:num_locks), &
#endif
!$OMP REDUCTION(+:pe,tp)

#if DEBUG_OMP_TIMING
!$  thread_num = omp_get_thread_num()
!$  start_time = omp_get_wtime()
#endif

!$ neighlc=0 !!(null value = neighbour link-cell is not set)

!$OMP DO
    !! calculate force on particles and their neighbours
    particleloop: do i=1,simparam%nm
       
       !!temporary force accumulator for particle i
       fxi=0.d0 ; fyi=0.d0 ; fzi=0.d0

       !! loop through a particle's neighbour list
       neighbourloop: do j=1,numn(i)
          
          !! index of i particle's j neighbour
          nlist_ji = nlist(j,i)

          !! fractional separation of particle i and neighbour j 
          dx=x0(i)-x0(nlist_ji)
          dy=y0(i)-y0(nlist_ji)
          dz=z0(i)-z0(nlist_ji)
          
          !! get real spatial separation from fractional components dx/y/z
          call pr_get_realsep_from_dx(r,dx,dy,dz)
          r_recip = 1.0d0 / r   !! Calculate the reciprical

          !! pair potential pp
          pp = vee(r,atomic_number(i),atomic_number(nlist_ji))
          
          !! pair pot. force is (-1/r) * derivative of pair potential        
          fpp = -dvee(r,atomic_number(i),atomic_number(nlist_ji)) * r_recip
          
          !! accumulate the potential energy
          pe = pe + pp
          
          !! cohesive pot. force is (-1/r) * derivative of cohesive potential
          fcp = -1.d0*( &
               dphi(r,atomic_number(i),atomic_number(nlist_ji))*dafrho(i) + &
               dphi(r,atomic_number(nlist_ji),atomic_number(i))*dafrho(nlist_ji) &
               ) * r_recip
          
          !! fp is the total force on atom i from atom  nlist_ji
          fp = fpp + fcp

          !! calculate spatial separation components from dx
          rxij=b0(1,1)*dx+b0(1,2)*dy+b0(1,3)*dz
          ryij=b0(2,1)*dx+b0(2,2)*dy+b0(2,3)*dz
          rzij=b0(3,1)*dx+b0(3,2)*dy+b0(3,3)*dz

          	
		  if (simparam%atomstress) then	
		  	stressx(i) = stressx(i) + rxij*fp	
		  	stressy(i) = stressy(i) + ryij*fp	
		 	stressz(i) = stressz(i) + rzij*fp	
		  endif
          !! apply fp componentwise to tp
          !! don't include stress due to forces between fixed atoms
          !! kinetic term doesn't matter because fixed atoms dont contribute
         if((atomic_mass(i)+atomic_mass(nlist_ji)).gt.0.1) then
          tp(1,1)=tp(1,1)+dx*rxij*fp
          tp(2,1)=tp(2,1)+dx*ryij*fp
          tp(3,1)=tp(3,1)+dx*rzij*fp
          tp(1,2)=tp(1,2)+dy*rxij*fp
          tp(2,2)=tp(2,2)+dy*ryij*fp
          tp(3,2)=tp(3,2)+dy*rzij*fp
          tp(1,3)=tp(1,3)+dz*rxij*fp
          tp(2,3)=tp(2,3)+dz*ryij*fp
          tp(3,3)=tp(3,3)+dz*rzij*fp
         endif
          ddfx = -dx*fp
          ddfy = -dy*fp
          ddfz = -dz*fp

          
!$ !! set/reset region locks when changing neighbour link cell
!$ if (ic(nlist_ji).ne.neighlc)then
!$   if(neighlc.gt.0)then !!unset old neighbour link-cell
!$     call omp_unset_lock(lc_lock(neighlc))
!$   end if
!$   neighlc=ic(nlist_ji)  !!set neighlc to the current link-cell
!$   call omp_set_lock(lc_lock(neighlc))
#if DEBUG_OMP_LOCKS
!$   num_locks = num_locks + 1
#endif
!$ end if
          
          !! update force of particle's neighbour
          fx(nlist_ji)=fx(nlist_ji)+ddfx
          fy(nlist_ji)=fy(nlist_ji)+ddfy
          fz(nlist_ji)=fz(nlist_ji)+ddfz

          !! update temp force accumulator for particle i
          fxi=fxi+ddfx
          fyi=fyi+ddfy
          fzi=fzi+ddfz


       end do neighbourloop


!$ !! set/reset region locks when updating own particle
!$ if (ic(i).ne.neighlc)then
!$  call omp_unset_lock(lc_lock(neighlc))
!$  neighlc=ic(i)  !!set neighlc to the current link-cell
!$  call omp_set_lock(lc_lock(neighlc))
#if DEBUG_OMP_LOCKS
!$  num_locks = num_locks + 1
#endif
!$ end if


       !!update force on particle i after accumulating over all neighbours
       fx(i)=fx(i)-fxi
       fy(i)=fy(i)-fyi
       fz(i)=fz(i)-fzi
 

    end do particleloop

!$OMP END DO NOWAIT

!$  !! release all locks
!$  call omp_unset_lock(lc_lock(neighlc))

#if DEBUG_OMP_TIMING
!$  write(*,*) "Thread ", thread_num, " time: ", omp_get_wtime() - start_time
#endif

! The fist thread to finish the loop above can get on with the next task
!$OMP SINGLE

#if DEBUG_OMP_LOCKS
    write(*,*)"Num locks: ", num_locks
#endif

    !! calculate tc
    tc(1,1)=b0(2,2)*b0(3,3)-b0(2,3)*b0(3,2)
    tc(2,1)=b0(3,2)*b0(1,3)-b0(1,2)*b0(3,3)
    tc(3,1)=b0(1,2)*b0(2,3)-b0(2,2)*b0(1,3)
    tc(1,2)=b0(2,3)*b0(3,1)-b0(3,3)*b0(2,1)
    tc(2,2)=b0(3,3)*b0(1,1)-b0(1,3)*b0(3,1)
    tc(3,2)=b0(1,3)*b0(2,1)-b0(1,1)*b0(2,3)
    tc(1,3)=b0(2,1)*b0(3,2)-b0(3,1)*b0(2,2)
    tc(2,3)=b0(3,1)*b0(1,2)-b0(1,1)*b0(3,2)
    tc(3,3)=b0(1,1)*b0(2,2)-b0(2,1)*b0(1,2)

    
    call kinten
    
#if DEBUG_OMP_TIMING
!$  write(*,*) "Thread ", thread_num, " time: ", omp_get_wtime() - start_time
#endif

!$OMP END SINGLE


!$OMP END PARALLEL
! Can't include the following in the parallel section as it depends
! on the completion of the force loop for tp
   
    !! force on the box from kinetic term, and external pressure
    do i=1,nmat
       do j=1,nmat
          fb(i,j)=tk(i,j)+tp(i,j)-simparam%press*tc(i,j)
       end do
    end do

!!$  !! Optional for debug purposes (efs.out)
!!$  !! Write out energy, forces and stress to file (sanity check)
!!$  call write_energy_forces_stress()
    
    return
  end subroutine force
  
  

  !---------------------------------------------------------------------
  !
  ! subroutine energy_calc
  !
  ! computes energy of the particles
  !
  !---------------------------------------------------------------------
  subroutine energy_calc
    
    integer :: i, j, k
    integer :: nlist_ji
    real(kind_wp) :: cx, cy, cz
    real(kind_wp) :: dxminu, dyminu, dzminu
    real(kind_wp) :: dxplus, dyplus, dzplus
    real(kind_wp) :: dx, dy, dz
    real(kind_wp) :: r, rsq, pp
    real(kind_wp) :: rxij, ryij, rzij !< spatial separation components
    real(kind_wp), parameter :: point5=0.5d0


!$  !!OpenMP reqd (local declarations)
!$  integer :: neighlc             !< link cell index of the current neighbour
    !! update module copy of simulation parameters
    simparam=get_params()
   
!$OMP PARALLEL PRIVATE( i, j, nlist_ji, dx, dy, dz, r, pp,&
!$OMP rxij, ryij, rzij), &
#if DEBUG_OMP_TIMING
!$OMP PRIVATE( thread_num, start_time ), &
#endif
!$OMP DEFAULT(NONE), &
!$OMP SHARED( simparam,x0,y0,z0,atomic_number,afrho,en_atom,numn,nlist )
 
!$OMP DO
   do i=1,simparam%nm
       en_atom(I)=afrho(i) 
    end do
    !$OMP END DO
   
    !! calculate energy on particles and their neighbours
    !$OMP DO
    
    particleloop: do i=1,simparam%nm
       !! loop through a particle's neighbour list
       neighbourloop: do j=1,numn(i)
          
          !! index of i particle's j neighbour
          nlist_ji = nlist(j,i)
          !! fractional separation of particle i and neighbour j 
          dx=x0(i)-x0(nlist_ji)
          dy=y0(i)-y0(nlist_ji)
          dz=z0(i)-z0(nlist_ji)
          !! get real spatial separation from fractional components dx/y/z
          call pr_get_realsep_from_dx(r,dx,dy,dz)

          !! pair potential pp  
          pp = vee_src(r,atomic_number(i),atomic_number(nlist_ji))
          !! accumulate the potential energy
          !$OMP atomic
          en_atom(i)=en_atom(i)+PP/2.d0 
          !$OMP atomic         
          en_atom(nlist_ji)=en_atom(nlist_ji)+PP/2.d0          

       end do neighbourloop


    end do particleloop
        
        !$OMP  END DO
    
!$OMP END PARALLEL


!!$  !! Optional for debug purposes (efs.out)
!!$  !! Write out energy, forces and stress to file (sanity check)
!!$  call write_energy_forces_stress()
 
    return
  end subroutine energy_calc 
  



  !---------------------------------------------------------------------
  !
  ! rhoset
  !
  ! set the density function f(rho(i)) for the Finnis-Sinclair potential
  ! set the cohesive potential: sum of f(rho(i))
  ! modified so that the "density function"
  !
  !---------------------------------------------------------------------
  subroutine rhoset(phi_local,rho_local)

    integer :: nm    ! number of atoms in loop
    integer :: i, j                   !< loop variables
    integer ::  nlist_ji              !< scalar neighbour index
    real(kind_wp) :: r                !< real spatial particle separation
    real(kind_wp) :: dx, dy, dz       !< fractional separation components
    real(kind_wp) :: rho_tmp          !< Temporary accumulator for rho
     real(kind_wp) :: phi_local             ! declare the function to be summed
     real(kind_wp) :: rho_local(:)     ! the sum of phi
!$  !!OpenMP reqd (local declarations)
!$  integer :: neighlc             !< link cell index of the current neighbour

    !get params
    simparam=get_params()
    !! set rho to zero
    rho_local(:)=0.0d0

    !! calculate rho_local
    
!$OMP PARALLEL PRIVATE( neighlc, i, j, nlist_ji, r, dx, dy, dz, rho_tmp ), &
!$OMP DEFAULT(NONE), &
!$OMP SHARED(nlist, atomic_number, ic, simparam, numn, x0, y0, z0, lc_lock, rho_local )

!$  neighlc = 0

!$OMP do
    rhocalc: do i=1,simparam%nm
       
       ! Reset my temporary rho accumulator
       rho_tmp = 0.d0

       !!loop through neighbours of i     
       do j=1,numn(i)        

          !! index
          nlist_ji  = nlist(j,i)

          !! real spatial separation of particles i and j
          dx=x0(i)-x0(nlist_ji)
          dy=y0(i)-y0(nlist_ji)
          dz=z0(i)-z0(nlist_ji)

          call pr_get_realsep_from_dx(r,dx,dy,dz)
          
!$ !! set/reset region locks when changing neighbour link cell
!$ if (ic(nlist_ji).ne.neighlc)then
!$   if(neighlc.gt.0)then !!unset old neighbour link-cell
!$     call omp_unset_lock(lc_lock(neighlc))
!$   end if
!$   neighlc=ic(nlist_ji)  !!set neighlc to the current link-cell
!$   call omp_set_lock(lc_lock(neighlc))
!$ end if
          
           
          rho_local(nlist_ji) =  rho_local(nlist_ji) + phi_local(r,atomic_number(nlist_ji),atomic_number(i))
          
          ! Update my own temporary accumulator
          rho_tmp = rho_tmp + phi_local(r,atomic_number(i),atomic_number(nlist_ji))
       
       end do
          
!$ !! set/reset region locks when updating own particle
!$ if (ic(i).ne.neighlc)then
!$  call omp_unset_lock(lc_lock(neighlc))
!$  neighlc=ic(i)  !!set neighlc to the current link-cell
!$  call omp_set_lock(lc_lock(neighlc))
!$ end if

        !! cohesive potential phi at r
        rho_local(i) =  rho_local(i) + rho_tmp

    end do rhocalc
!$OMP END DO NOWAIT

!$  !! release all locks
!$  call omp_unset_lock(lc_lock(neighlc))
!$OMP END PARALLEL


    return

  end subroutine rhoset

  !-------------------------------------------------------------
  !
  ! subroutine write_energy_forces_stress
  !
  ! writes out energy, forces and stress to file (sanity check)
  !
  !-------------------------------------------------------------
  subroutine write_energy_forces_stress()
    integer :: unit_efs
    real(kind_wp) :: fdummy(3),sigma(3,3)
    integer :: i, j, k
    simparam=get_params()

    !! open file
    unit_efs=newunit()
    open(unit_efs,file="efs.out",status='unknown')

    !! write energy
    write(unit_efs,*)"energy" , pe

    !! write force components
    do i=1,simparam%nm
       fdummy=(/fx(i),fy(i),fz(i)/)
       write(unit_efs,*) sum((/(b0(1,j)*fdummy(j),j=1,3)/)), &
            sum((/(b0(2,j)*fdummy(j),j=1,3)/)), &
            sum((/(b0(3,j)*fdummy(j),j=1,3)/))
    end do

    !! write stress
    do i=1,3
       do j=1,3
          sigma(i,j)=-1.d0*sum((/(b0(j,k)*tp(i,k),k=1,3)/))/vol
       end do
    end do
    write(unit_efs,*) sigma

    !! close
    close(unit_efs)
  end subroutine write_energy_forces_stress


  !-------------------------------------------------------------
  !
  ! subroutine write_stress
  !
  ! writes out energy, forces and stress to file (sanity check)
  !
  !-------------------------------------------------------------
  subroutine write_stress(unit)

    real(kind_wp) :: fdummy(3),sigma(3,3)
    integer :: i, j, k
    integer :: unit
    simparam=get_params()

    !! write stress
    do i=1,3
       do j=1,3
          sigma(i,j)=-1.d0*sum((/(b0(j,k)*(tp(i,k)+tk(i,k)),k=1,3)/))/vol
       end do
    end do
    do i=1,3
        write(unit,99) i,(sigma(i,j)*press_to_gpa,j=1,3)
 99    format("STRESS I=",I2, 3e14.6," GPa")       
    end do

  end subroutine write_stress

  subroutine update_therm_avs(s1,s2,s3)

    !! argument declarations
    real(kind_wp) :: s1            !< force accumulator
    real(kind_wp) :: s2            !< force squared accumulator
    real(kind_wp) :: s3            !< kinetic energy accumulator

    integer :: i, j, k

    real(kind_wp) :: sxi, syi, szi !< local variables
    real(kind_wp) :: fxip, fyip, fzip, f2  !< local variables
    real(kind_wp) :: fxi, fyi, fzi, rxi, ryi, rzi  !< local variables

    real(kind_wp) :: b0_XXdet, b0_XYdet, b0_XZdet, b0_YXdet, b0_YYdet, b0_YZdet, b0_ZXdet, b0_ZYdet, b0_ZZdet

    simparam=get_params()


    !! reset accumulators
    S1=0.0d0
    S2=0.0d0
    S3=0.0d0


    !! initialise tensors to zero
    tg(:,:)=0.0d0
    tgdot(:,:)=0.0d0

    !! calculate tg and tgdot (accumulate over k)
    do i=1,nmat
       do k=1,nmat
          do j=1,nmat
             tg(i,j)=tg(i,j)+b0(k,i)*b0(k,j)
       if(simparam%ivol.ne.1) tgdot(i,j)=tgdot(i,j)+ b1(k,i)*b0(k,j)+b0(k,i)*b1(k,j)
          end do
       end do
    end do
    
    !! recalculate tgid here
    call pr_get_tgid
    
    !! update box volume
    call pr_get_metric_tensor

    !! vol*inv(b0)
    b0_xxdet=(b0(2,2)*b0(3,3)-b0(2,3)*b0(3,2))/vol
    b0_xydet=(b0(2,3)*b0(3,1)-b0(3,3)*b0(2,1))/vol
    b0_xzdet=(b0(2,1)*b0(3,2)-b0(3,1)*b0(2,2))/vol
    b0_yxdet=(b0(3,2)*b0(1,3)-b0(1,2)*b0(3,3))/vol
    b0_yydet=(b0(1,1)*b0(3,3)-b0(1,3)*b0(3,1))/vol
    b0_yzdet=(b0(3,1)*b0(1,2)-b0(1,1)*b0(3,2))/vol
    b0_zxdet=(b0(1,2)*b0(2,3)-b0(2,2)*b0(1,3))/vol
    b0_zydet=(b0(1,3)*b0(2,1)-b0(1,1)*b0(2,3))/vol
    b0_zzdet=(b0(1,1)*b0(2,2)-b0(1,2)*b0(2,1))/vol

    do i=1,simparam%nm

       !! cycle if vacancy
       if ( atomic_number(i).eq.0 ) cycle

       sxi=tgid(1,1)*x1(i)+tgid(1,2)*y1(i)+tgid(1,3)*z1(i)
       syi=tgid(2,1)*x1(i)+tgid(2,2)*y1(i)+tgid(2,3)*z1(i)
       szi=tgid(3,1)*x1(i)+tgid(3,2)*y1(i)+tgid(3,3)*z1(i)

       fxip=2.0d0*x2(i)+sxi
       fyip=2.0d0*y2(i)+syi
       fzip=2.0d0*z2(i)+szi

       !! force components
       fxi=b0_xxdet*fxip+b0_xydet*fyip+b0_xzdet*fzip
       fyi=b0_yxdet*fxip+b0_yydet*fyip+b0_yzdet*fzip
       fzi=b0_zxdet*fxip+b0_zydet*fyip+b0_zzdet*fzip

       !! calculate and accumulate total force and its square
       f2=fxi*fxi+fyi*fyi+fzi*fzi
       s1=s1+f2
       s2=s2+f2*f2

       !! s3 is accumulated kinetic energy
       rxi=b0(1,1)*x1(i)+b0(1,2)*y1(i)+b0(1,3)*z1(i)
       ryi=b0(2,1)*x1(i)+b0(2,2)*y1(i)+b0(2,3)*z1(i)
       rzi=b0(3,1)*x1(i)+b0(3,2)*y1(i)+b0(3,3)*z1(i)
       s3=s3+atomic_mass(i)*(rxi*rxi+ryi*ryi+rzi*rzi)
    end do

  end subroutine update_therm_avs
  
  !-------------------------------------------------------------
  !routine to calculate stress on an atomic scale using eq 6 from Modelling and  Simulation in Mater. Sci. Eng. 1 (1993) 315-333.
  !is called automatically just after force calculation for efficiency, calling it at other times may result in the force part being 
  !-------------------------------------------------------------
  !half a step out from the velocity part.
  subroutine atomic_stress_calc
		real(kind_wp) :: atomic_vol,vx,vy,vz
		integer :: i
		!subtract kinetic enrgy of each term
		do i=1,simparam%nm
		   !need component wise KE
		    vx=b0(1,1)*x1(i)
		    vy=b0(2,2)*y1(i)
            vz=b0(3,3)*z1(i)
            stressx(i) = stressx(i) - atomic_mass(i)*(vx*vx)/((simparam%deltat**2)*2)
            stressy(i) = stressy(i) - atomic_mass(i)*(vy*vy)/((simparam%deltat**2)*2)
            stressz(i) = stressz(i) - atomic_mass(i)*(vz*vz)/((simparam%deltat**2)*2)
            
		end do
		!strictly only true for an entirly filled box with no off diagonal terms.
		atomic_vol = B0(1,1)*B0(2,2)*B0(3,3)/simparam%nm
		!normalise by volume and a factor of 2  
		 stressx(:) = stressx(:)/(2*atomic_vol)
		 stressy(:) = stressy(:)/(2*atomic_vol)
		 stressz(:) = stressz(:)/(2*atomic_vol)
  end subroutine atomic_stress_calc
  !-------------------------------------------------------------
  !write atomic stress data 
  !-------------------------------------------------------------
  subroutine write_atomic_stress(file_counter)
  integer :: i
    integer file_counter
character(len=34) :: ci
character(len =3) :: pad
write(ci,'(i0)') file_counter

!ci = trim(ci)
!ci = adjustr(ci)


if (file_counter<10)then
 pad = '0'
else
pad = ''
end if
ci = 'atomicStress'//trim(pad)//trim(ci)//'.out'
if(file_counter .eq. -1) then
ci = 'lastAtomicStress.out'
end if
  	  open(5473,file=ci,status='unknown')

    !! write energy
    do i=1,simparam%nm
    write(5473,*)  stressx(i),stressy(i),stressz(i),x0(i),y0(i),z0(i)
    end do
    close(5473)
  end subroutine write_atomic_stress
  
  
		!returns energy for each atom due to pair term and embedding term (i.e. full potenial energy)
	function energy_pair_emb()

		real(kind_wp) :: energy_pair_emb
		real(kind_wp) :: te,tpp,tpe
		
		!call rhoset
		call energy_calc
		energy_pair_emb = sum(en_atom)

		return
	end function energy_pair_emb
	


end module dynamics_m
