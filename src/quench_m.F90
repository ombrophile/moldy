!!========================================================================
!!
!! MOLDY - Short Range Molecular Dynamics
!! Copyright (C) 2009 G.Ackland, K.D'Mellow, University of Edinburgh.
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
!! or by writing to Prof. G Ackland, School of Physics, JCMB,
!! University of Edinburgh, Edinburgh, EH9 3JZ, UK.
!!
!!========================================================================

module quench_m

  !! standard dependencies
  use constants_m
  use params_m
  use constants_m

  !! functional dependencies
  use analysis_m
  use thermostat_m
  use particles_m
  use dynamics_m
  use system_m
  use potential_m
  use parinellorahman_m
  use neighbourlist_m
  use linkcell_m


  private


  !! public interfaces to this module
  public :: quench
  public :: init_quench_m, cleanup_quench_m


  !! module private variables
  integer :: nvari
  real(kind_wp), allocatable :: energy(:)
  real(kind_wp), allocatable :: x(:), g(:)
  integer :: istat                         !< memory allocation status
  type(simparameters), save :: simparam    !< module copy of simulation parameters


contains


  !--------------------------------------------------------------------------------
  !
  !  initialisation routines (public)
  !
  !  init_quench_m, cleanup_quench_m
  !
  !--------------------------------------------------------------------------------
  subroutine init_quench_m
    simparam=get_params()
    NVARI=3*simparam%NM+9
    allocate(x(nvari),g(nvari),stat=istat)
    if(istat.ne.0)stop 'ALLOCATION ERROR (init_quench_m) - Possibly out of memory.'
  end subroutine init_quench_m
  subroutine cleanup_quench_m
    deallocate(x,g)
  end subroutine cleanup_quench_m

  

  !----------------------------------------------------------
  !
  ! quench (public)
  !
  !----------------------------------------------------------
  subroutine quench

    !! local variables
    integer :: i, j
    integer :: nm3, i3, i31, i32, i33
    real(kind_wp) :: f, dfn, acc, boxke
    simparam=get_params()

    write(unit_stdout,200)simparam%nm
200 format(' QUENCH, FINDING MINIMUM ENERGY CONFIGURATION OF', &
         &  I5,' ATOMS')

    do i=1,simparam%nm
       i31=3*i-2
       i32=i31+1
       i33=i32+1
       x(i31)=x0(i)
       x(i32)=y0(i)
       x(i33)=z0(i)
    end do

    nm3=3*simparam%nm
    do i=1,nmat
       do j=1,nmat
          nm3=nm3+1
          x(nm3) = b0(i,j)
       end do
    end do

    !! allocate energy for minimisation (used in derivs)
    allocate(energy(simparam%nm),stat=istat)
    if(istat.ne.0)stop 'ALLOCATION ERROR (quench) - Possibly out of memory.'

    !! Harwell subroutine library's VA14CD
    dfn = 0.1d0
    acc= 5.0e-8*simparam%NM !! accuracy depends on number of atoms 
    call va14cd(derivs,nvari,f,dfn,acc)
    pe = f

    !! sync params after va14cd
    call set_params(simparam)

    !! output results
    write(unit_stdout,*)'ATOM,  ENERGY'
    do i=1,simparam%nm
!     write(unit_stdout,*)i,energy(i)
       i3=3*i-2
       i31=i3+1
       i32=i3+2
       x0(i) = x(i3)
       y0(i) = x(i31)
       z0(i) = x(i32)
    end do

    !! deallocate energy when finished with it (used in derivs)
    deallocate(energy)

    !! extract b0 from 
    nm3=3*simparam%nm
    do i=1,nmat
       do j=1,nmat
          nm3=nm3+1
          b0(i,j) = x(nm3)
       end do
    end do

    do i=1,nmat
       do j=1,nmat
          b1(i,j)=0.0
          b2(i,j)=0.0
          b3(i,j)=0.0
       end do
    end do

    !calculate the box volume (in analysis_m)
    call pr_get_metric_tensor


    do i=1,simparam%nm
       x1(i)=0.0
       y1(i)=0.0
       z1(i)=0.0
       x2(i)=0.0
       y2(i)=0.0
       z2(i)=0.0
       x3(i)=0.0
       y3(i)=0.0
       z3(i)=0.0
       if(simparam%ivol.lt.3) x0(i)=x0(i)-aint(2.0*x0(i))
       if(simparam%ivol.lt.3) y0(i)=y0(i)-aint(2.0*y0(i))
       if(simparam%ivol.lt.2.or.simparam%ivol.ge.4) z0(i)=z0(i)-aint(2.0*z0(i))

    end do
    call set_temp(0.0_kind_wp)
    ke=0.0
    te=ke+pe
    boxke=0.0

    simparam%boxtem=0.0

    call set_params(simparam)

    h=te+simparam%press*vol
    th=h

    return

  end subroutine quench


  !--------------------------------------------------------------------------------
  !
  !  subroutine derivs
  !
  !  computes energy derivatives g
  !
  !--------------------------------------------------------------------------------
  subroutine derivs(n,f)

    !! argument variables
    integer :: n
    real(kind_wp) :: f

    !! local variables
    integer :: i, j, k
    integer :: i31, i32, i33
    integer :: nlisti, nm3
    integer :: ijs
    real(kind_wp) :: dx, dy, dz             !< fractional particle separation
    real(kind_wp) :: r                      !< spatial separation
    real(kind_wp) :: rxij,ryij,rzij         !< physical separation components
    real(kind_wp) :: fcp, fp, fpp, pp, rsq
    real(kind_wp) :: xi, yi, zi
    real(kind_wp) :: dfx, dfy, dfz
    real(kind_wp) :: xnbr,ynbr,znbr !< positions between neighbours
    real(kind_wp) :: tp(nmat,nmat)
!    simparam=get_params()

    nm3=3*simparam%nm
    do i=1,nmat
       do j=1,nmat
          nm3=nm3+1
          b0(i,j) = x(nm3)
       end do
    end do
    do i=1,simparam%nm
       energy(i)= 0.0d0
       i31=3*i-2
       i32=i31+1
       i33=i32+1
       x0(i) = x(i31)
       y0(i) = x(i32)
       z0(i) = x(i33)
       fx(i)=0.0d0
       fy(i)=0.0d0
       fz(i)=0.0d0
    end do

    !! compute metric tensor
    call pr_get_metric_tensor

    !increment neighbour list update counter and update if necessary
    simparam%ntc = simparam%ntc + 1
    if(simparam%ntc.eq.1) then
       call set_params(simparam)
       call update_neighbourlist
    end if

    !! set rho(i) and related quantities required for the finnis-sinclair potential
    call rhoset

    call embed(pe)

    !! compute h transposed * h  = g
    do i=1,nmat
       do j=1,nmat
          tg(i,j)=0.0d0
       end do
       do k=1,nmat
          do j=1,nmat
             tg(i,j)=tg(i,j)+b0(k,i)*b0(k,j)
          end do
       end do
    end do

    tp(:,:)=0.0d0

    ! use the neighbour list
    mainloop:do i=1,simparam%nm
       xi=x0(i)
       yi=y0(i)
       zi=z0(i)
       k=numn(i)
       if(k.eq.0) cycle mainloop

       do j=1,k
          nlisti  = nlist(j,i)

          !! fractional position of the j neighbour of atom i
          xnbr = x0(nlisti)
          ynbr = y0(nlisti)
          znbr = z0(nlisti)

          !! fractional separation between atoms i and j
          dx=xi-xnbr
          dy=yi-ynbr
          dz=zi-znbr

          !! evaluate r, the physical separation between atoms i and j
          call pr_get_realsep_from_dx(r,dx,dy,dz)


          !! evaluate pair potential pp and (-1/r)*(derivative of pp), fpp:
          !! ie   fpp  = (-1/r) d pp /d r
          !!      r    = interatomic distance
          !!      rsq  = r*r
          pp  =   vee(r,atomic_number(i),atomic_number(nlisti))
          fpp = -dvee(r,atomic_number(i),atomic_number(nlisti))/r
          pe = pe+pp
          energy(i) = energy(i)+pp/2.d0
          energy(nlisti) = energy(nlisti)+pp/2.d0


          !! evaluate (-1/r)*(derivative of cohesive potential), fcp
          fcp = -1.d0*( &
               dphi(r,atomic_number(i),atomic_number(nlisti))*dafrho(i) + &
               dphi(r,atomic_number(nlisti),atomic_number(i))*dafrho(nlisti) &
               )/r


          !! fp is (1/r)*(force on atom i from atom j)
          fp = fpp + fcp

          !! calculate spatial separation components from dx
          rxij=b0(1,1)*dx+b0(1,2)*dy+b0(1,3)*dz
          ryij=b0(2,1)*dx+b0(2,2)*dy+b0(2,3)*dz
          rzij=b0(3,1)*dx+b0(3,2)*dy+b0(3,3)*dz

          !! apply fp componentwise to tp
          tp(1,1)=tp(1,1)+dx*rxij*fp
          tp(2,1)=tp(2,1)+dx*ryij*fp
          tp(3,1)=tp(3,1)+dx*rzij*fp
          tp(1,2)=tp(1,2)+dy*rxij*fp
          tp(2,2)=tp(2,2)+dy*ryij*fp
          tp(3,2)=tp(3,2)+dy*rzij*fp
          tp(1,3)=tp(1,3)+dz*rxij*fp
          tp(2,3)=tp(2,3)+dz*ryij*fp
          tp(3,3)=tp(3,3)+dz*rzij*fp

          dfx = -dx*fp
          dfy = -dy*fp
          dfz = -dz*fp

          !! update force of particle's neighbour
          fx(nlisti)=fx(nlisti)+dfx
          fy(nlisti)=fy(nlisti)+dfy
          fz(nlisti)=fz(nlisti)+dfz

          !! update force of particle
          fx(i)=fx(i)-dfx
          fy(i)=fy(i)-dfy
          fz(i)=fz(i)-dfz

       end do


    end do mainloop


    !! start calculating the inverse of b0
    tc(1,1)=b0(2,2)*b0(3,3)-b0(2,3)*b0(3,2)
    tc(2,1)=b0(3,2)*b0(1,3)-b0(1,2)*b0(3,3)
    tc(3,1)=b0(1,2)*b0(2,3)-b0(2,2)*b0(1,3)
    tc(1,2)=b0(2,3)*b0(3,1)-b0(3,3)*b0(2,1)
    tc(2,2)=b0(3,3)*b0(1,1)-b0(1,3)*b0(3,1)
    tc(3,2)=b0(1,3)*b0(2,1)-b0(1,1)*b0(2,3)
    tc(1,3)=b0(2,1)*b0(3,2)-b0(3,1)*b0(2,2)
    tc(2,3)=b0(3,1)*b0(1,2)-b0(1,1)*b0(3,2)
    tc(3,3)=b0(1,1)*b0(2,2)-b0(2,1)*b0(1,2)


    !! evaluate d(pe)/d(s) from generalised force (fx,fy,fz)
    do i=1,simparam%nm
    energy(i)=energy(i) - emb(rho(i),atomic_number(i))
       i31=3*i-2
       i32=i31+1
       i33=i32+1
       g(i31)= (- tg(1,1)*fx(i) - tg(1,2)*fy(i) - tg(1,3)*fz(i) )
       g(i32)= (- tg(2,1)*fx(i) - tg(2,2)*fy(i) - tg(2,3)*fz(i) )
       g(i33)= (- tg(3,1)*fx(i) - tg(3,2)*fy(i) - tg(3,3)*fz(i) )
    end do


    nm3 = 3*simparam%nm
    if(simparam%ivol.lt.1.or.simparam%ivol.eq.4) then
       do i=1,nmat
          do j=1,nmat
             nm3=nm3+1
             !  this line applies the grain boundary boundary condition
             if(simparam%ivol.eq.4.and.(i*j).ne.9) cycle
             g(nm3) = (-tp(i,j)+simparam%press*tc(i,j) )
             !  orthogonal box
             !        g(nm3)=0
             !       if(i.eq.j) g(nm3) = (-tp(i,j)+press*tc(i,j) )
          end do
       end do
    endif
    write(unit_stdout,1359)pe/simparam%nm,vol/simparam%nm
1359 format(' COHESIVE ENERGY ',d16.8, 'VOLUME',d16.8 )
    !! write stress
    do i=1,3
        write(unit_stdout,99) i,(-1.d0*sum((/(b0(j,k)*tp(i,k),k=1,3)/))/vol*press_to_gpa,j=1,3)
 99    format("STRESS I=",I2, 3e14.6," GPa")       
    end do



    f = pe + simparam%press*vol

    return
  end subroutine derivs


!--------------------------------------------------------------------------------
!
! VA14CD (module private)
!
! Subroutine VA14CD is adapted from the Harwell subroutine library
! (1979 Edition).
!
! See http://www.cse.scitech.ac.uk/nag/hsl/ for further details.
! This can be used without charge for non-commercial purposes, but cannot
! be included under GPL.
!
!--------------------------------------------------------------------------------
SUBROUTINE VA14CD(FUNCT,N,F,DFN,ACC)

  integer :: N
  integer :: i, ipabs, ipr, iretry, itcrs, iterc, maxfnc, maxfnk, noerr
  integer :: IFLAG
  real(kind_wp) :: F, DFN, ACC, C, DTEST, GAMMA, TOPLIN, XOLD
  real(kind_wp) :: DR(N),DGR(N),D(N),GS(N),XX(N),GG(N)
  real(kind_wp) :: beta, clt, dginit, dgstep, finit, fmin, gamden, ggstar
  real(kind_wp) :: gm, gmin, gnew, gsinit, gsumsq
  real(kind_wp) :: xbound, xmin, xnew

  interface
     subroutine funct(N,F)
       use constants_m
       integer :: N
       real(kind_wp) :: F
     end subroutine funct
  end interface

  !! get local copy of parameters
  simparam=get_params()


!     PREPARE FOR THE FIRST ITERATION
      XNEW=0.0D0
      DGSTEP=0.0D0
      ITCRS=0
      MAXFNK=0
      FMIN=0.0D0
      DGINIT=0.0D0
      XMIN=0.0
      FINIT=0.0
      GSINIT=0.0
      GMIN=0.0
      GM=0.0
      XBOUND=0.0
      CLT =0.0
      GNEW = 00.0D0
      GGSTAR = 0.0D0
      BETA = 0.0D0
      NOERR =0
      GAMDEN=0.0D0
      IFLAG=0
      IPABS=ABS(SIMPARAM%IPRINT)
      IPR=IPABS
      IRETRY=-2
      ITERC=0
      MAXFNC=1
      GO TO 190
   10 XNEW=ABS(DFN+DFN)/GSUMSQ
      DGSTEP=-GSUMSQ
   20 ITCRS=N+1
!     ENSURE THAT F IS THE BEST CALCULATED FUNCTION VALUE
   30 IF (MAXFNK.GE.MAXFNC) GO TO 50
      F=FMIN
      DO 40 I=1,N
      X(I)=XX(I)
   40 G(I)=GG(I)
   50 IF (IFLAG.GT.0) GO TO 230
!     MAKE A STEEPEST DESCENT RESTART FROM THE BEST POINT SO FAR
      IF (ITCRS.LE.N) GO TO 70
      DO 60 I=1,N
   60 D(I)=-G(I)
!     BEGIN THE ITERATION BY PROVIDING PRINTING
   70 IF (simparam%IPRINT.EQ.0) GO TO 150
      IF (IPR.LT.IPABS) GO TO 140
   80 WRITE (unit_stdout,90) ITERC,MAXFNC,F
   90 FORMAT (/5X,"ITERATION",I6,10X,"FUNCTION VALUES",I6/5X,"F =",1P,E20.13)
      IF (simparam%IPRINT.LT.0) GO TO 130
      WRITE (unit_stdout,100)
  100 FORMAT (/5X,'THE COMPONENTS OF X(.) ARE')
      WRITE (unit_stdout,110) (X(I),I=1,N)
  110 FORMAT (1P,5E10.3)
      WRITE (unit_stdout,120)
  120 FORMAT (/5X,'THE COMPONENTS OF G(.) ARE')
      WRITE (unit_stdout,110) (G(I),I=1,N)
  130 IF (IPR.EQ.0) GO TO 240
      IPR=0
  140 IPR=IPR+1
  150 ITERC=ITERC+1
!     CALCULATE THE INITIAL DIRECTIONAL DERIVATIVE
      DGINIT=0.D0
      DO 160 I=1,N
      GS(I)=G(I)
  160 DGINIT=DGINIT+D(I)*G(I)
!     RETURN OR RESTART IF THE SEARCH DIRECTION IS NOT DOWNHILL
      IF (DGINIT.GE.0.0D0) GO TO 320
!     SET THE DATA FOR THE INITIAL STEP ALONG THE SEARCH DIRECTION
      XMIN=0.D0
      FMIN=F
      FINIT=F
      GSINIT=GSUMSQ
      GMIN=DGINIT
      GM=DGINIT
      XBOUND=-1.0
      XNEW=XNEW*MIN(1.0d0,DGSTEP/DGINIT)
      DGSTEP=DGINIT
!     CALCULATE THE NEW FUNCTION AND GRADIENT
  170 C=XNEW-XMIN
      DTEST=0.D0
      DO 180 I=1,N
      X(I)=XX(I)+C*D(I)
  180 DTEST=DTEST+ABS(X(I)-XX(I))
      IF (DTEST.LE.0.0D0) CLT=0.7D0
      IF (DTEST.LE.0.0D0) GO TO 300
      IF (MAX(XBOUND,XMIN-C).LT.0.0D0) CLT=0.1D0
      MAXFNC=MAXFNC+1
 190  CALL FUNCT (N,F)
      WRITE (unit_stdout,90) ITERC,MAXFNC,F
!     CALCULATE THE NEW DIRECTIONAL DERIVATIVE
      IF (MAXFNC.LE.1) GO TO 210
      GNEW=0.D0
      DO 200 I=1,N
  200 GNEW=GNEW+D(I)*G(I)
!     TEST FOR CONVERGENCE
      IF (F.LT.FMIN) GO TO 210
      IF (F.GT.FMIN) GO TO 250
      IF (ABS(GNEW).GT.ABS(GMIN)) GO TO 250
  210 MAXFNK=MAXFNC
      GSUMSQ=0.D0
      DO 220 I=1,N
  220 GSUMSQ=GSUMSQ+G(I)**2
      IF (GSUMSQ.GT.ACC) GO TO 250
  230 IPR=0
      IF (simparam%IPRINT.NE.0) GO TO 80
  240 RETURN
!     RETURN IF MAXFN FUNCTION VALUES HAVE BEEN CALCULATED
  250 IF (MAXFNC.NE.simparam%NSTEPS) GO TO 270
      WRITE (unit_stdout,260)
  260 FORMAT (/5X,"RETURN FROM SUBROUTINE VA14AD", &
           & "BECAUSE MAXFN FUNCTION VALUES HAVE BEEN CALCULATED")
      IFLAG=1
      GO TO 30
!     STORE THE BEST VALUES OF X(.) AND G(.)
  270 IF (MAXFNK.LT.MAXFNC) GO TO 300
      DO 280 I=1,N
      XX(I)=X(I)
  280 GG(I)=G(I)
      IF (MAXFNC.LE.1) GO TO 10
!     CALCULATE THE NEW VALUE OF BETA
      GM=GNEW
      IF (GM.LE.DGINIT) GO TO 310
      GGSTAR=0.D0
      DO 290 I=1,N
  290 GGSTAR=GGSTAR+GS(I)*G(I)
      BETA=(GSUMSQ-GGSTAR)/(GM-DGINIT)
!     TEST IF THE LINE SEARCH IS SUFFICIENTLY ACCURATE
  300 IF (ABS(GM).GT.CLT*ABS(DGINIT)) GO TO 310
      IF (ABS(GM*BETA).LE.CLT*GSUMSQ) GO TO 380
!     RETURN OR RESTART IF THE LINE SEARCH HAS USED TOO MANY FUNCTIONS
  310 CLT=CLT+0.3D0
      IF (CLT.LE.0.8D0) GO TO 340
  320 IRETRY=-IRETRY
      IF (MIN0(IRETRY,MAXFNK).GE.2) GO TO 20
      WRITE (unit_stdout,330)GSUMSQ,ACC,F,FMIN
  330 FORMAT (/5X,' ERROR RETURN FROM SUBROUTINE VA14AD '/5X, &
           & ' IT MAY BE DUE TO A MISTAKE IN THE DEFINITION OF THE GRADIENT' &
           & /5X,'OR DUE TO A SMALL VALUE OF THE PARAMETER ACC'/5X,E10.3, &
           & '<',E10.3/5X,'Enthalpy is F=',E16.8, 'Lowest yet FMIN=',E16.8)
      noerr = noerr+1
      if (noerr.lt.5) GO TO 20
      IFLAG=2
      GO TO 30
!     SET XNEW TO THE NEXT DEFAULT VALUE OF THE LINE SEARCH
  340 XOLD=XNEW
      XNEW=0.5D0*(XMIN+XOLD)
      IF (MAXFNK.LT.MAXFNC) GO TO 350
      IF (GMIN*GNEW.LE.0.0D0) GO TO 350
      XNEW=10.0D0*XOLD
      IF (XBOUND.GE.0.0D0) XNEW=0.5D0*(XOLD+XBOUND)
!     ESTIMATE THE DERIVATIVE AT THE DEFAULT VALUE (two steps for CASTLE)
  350 toplin = (3.0D0*GNEW+GMIN-4.0D0*(F-FMIN)/(XOLD-XMIN))
      C = GNEW - toplin * (XOLD-XNEW)/(XOLD-XMIN)
!     REPLACE XMIN ETCETERA IF THE NEW FUNCTION VALUE IS BETTER
      IF (MAXFNK.LT.MAXFNC) GO TO 360
      IF (GMIN*GNEW.LE.0.0D0) XBOUND=XMIN
      XMIN=XOLD
      FMIN=F
      GMIN=GNEW
      GO TO 370
  360 XBOUND=XOLD
!     CALCULATE THE NEXT FUNCTION VALUE IN THE LINE SEARCH
  370 IF (C*GMIN.GE.0.0D0) GO TO 170
      XNEW=(XMIN*C-XNEW*GMIN)/(C-GMIN)
      GO TO 170
!     BRANCH IF THE ITERATION HAS NOT REDUCED F
  380 IF (DMIN1(F,FMIN).LT.FINIT) GO TO 390
      IF (GSUMSQ.GE.GSINIT) GO TO 320
!     BRANCH IF A RESTART IS NEEDED
  390 IF (ITCRS.GE.N) GO TO 420
      IF (ABS(GGSTAR).GE.0.2D0*GSUMSQ) GO TO 420
!     CALCULATE THE VALUE OF GAMMA FOR THE NEXT SEARCH DIRECTION
      GAMMA=0.D0
      C=0.D0
      DO 400 I=1,N
      GAMMA=GAMMA+GG(I)*DGR(I)
  400 C=C+GG(I)*DR(I)
      GAMMA=GAMMA/GAMDEN
!     RESTART IF THE NEW SEARCH DIRECTION IS NOT SUFFICIENTLY DOWNHILL
      IF (ABS(BETA*GM+GAMMA*C).GE.0.2D0*GSUMSQ) GO TO 420
!     CALCULATE THE NEW SEARCH DIRECTION
      DO 410 I=1,N
  410 D(I)=-GG(I)+BETA*D(I)+GAMMA*DR(I)
      ITCRS=ITCRS+1
      GO TO 30
!     APPLY THE RESTART PROCEDURE
  420 ITCRS=2
      GAMDEN=GM-DGINIT
      DO 430 I=1,N
      DR(I)=D(I)
      DGR(I)=GG(I)-GS(I)
  430 D(I)=-GG(I)+BETA*D(I)
      GO TO 30
      END SUBROUTINE

end module quench_m