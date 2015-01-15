# encoding: utf-8
# cython: profile=True
# filename: qmc.pyx
'''

File: qmc.py
Author: Hadayat Seddiqi
Date: 10.13.14
Description: Do the path-integral quantum annealing.
             See: 10.1103/PhysRevB.66.094203

'''

cimport cython
# from cython.parallel import prange
import numpy as np
cimport numpy as np

# @cython.profile(True)
@cython.boundscheck(False)
@cython.wraparound(False)
def QuantumMetropolisAccept(rng,
                            np.ndarray[np.float_t, ndim=1] svec, 
                            np.ndarray[np.float_t, ndim=1] tvec,
                            int sidx, 
                            int tidx,
                            np.ndarray[np.float_t, ndim=2] nb_pairs, 
                            float jperp, 
                            float T):
    """
    Determine whether to accept a spin flip or not. 

    Inputs: @svec     spin vector for this particular Trotter slice
            @tvec     spin vector along the Trotter dimension
            @sidx     spin index in the 2D lattice
            @tidx     Trotter slice index
            @nb_pairs list of 2-tuples that include all neighboring
                      indices and the J coupling values, i.e., looks
                      like: [ (nb_1, J[sidx,nb_1]), ... ].
            @jperp    coupling strength along the Trotter dimension
            @T        ambient temperature

    Returns: True  if move is accepted
             False if rejected
    """
    # define with cdefs to speed things up
    cdef float ediff = 0.0
    cdef int si = 0
    cdef int spinidx = 0
    cdef float jval = 0.0
    cdef int P = tvec.size
    cdef int tleft = 0
    cdef int tright = 0
    # loop through the neighbors
    for si in range(len(nb_pairs)):
        # get the neighbor spin index
        spinidx = nb_pairs[si][0]
        # get the coupling value to that neighbor
        jval = nb_pairs[si][1]
        # self-connections are not quadratic
        if spinidx == sidx:
            ediff += -2.0*svec[sidx]*jval
        else:
            ediff += -2.0*svec[sidx]*(jval*svec[int(spinidx)])
    # periodic boundaries
    if tidx == 0:
        tleft = P-1
        tright = 1
    elif tidx == P-1:
        tleft = P-2
        tright = 0
    else:
        tleft = tidx-1
        tright = tidx+1
    # now calculate between neighboring slices
    ediff += -2.0*svec[sidx]*(jperp*tvec[tleft])
    ediff += -2.0*svec[sidx]*(jperp*tvec[tright])
    # decide
    if ediff > 0.0:  # avoid overflow
        return True
    if np.exp(ediff/T) > rng.uniform(0,1):
        return True
    else:
        return False

# @cython.profile(True)
@cython.boundscheck(False)
@cython.wraparound(False)
def QuantumAnneal(np.ndarray[np.float_t, ndim=1] annealingSchedule,
                  int mcSteps,
                  int trotterSlices, 
                  float annealingTemperature, 
                  int nSpins, 
                  np.ndarray[np.float_t, ndim=2] configurations, 
                  np.ndarray[np.float_t, ndim=3] neighbors, 
                  rng):
    """
    Execute quantum annealing part using path-integral quantum Monte Carlo.
    The Hamiltonian is:

    H = -\sum_k^P( \sum_ij J_ij s^k_i s^k_j + J_perp \sum_i s^k_i s^k+1_i )

    where J_perp = -PT/2 log(tanh(G/PT)). The second term on the RHS is a 
    1D Ising chain along the extra dimension. In other words, a spin in this
    Trotter slice is coupled to that same spin in the nearest-neighbor slices.

    The quantum annealing is controlled by the transverse field which starts
    at @transFieldStart and decreases by @transFieldStep for @annealingSteps
    number of steps. The ambient temperature is @annealingTemperature, and the
    total number of spins is @nSpins. @isingJ and @perpJ give the parts of the
    Hamiltonian to calculate the energies, and @configurations is a list of
    spin vectors of length @trotterSlices. @rng is the random number generator.

    Returns: None (spins are flipped in-place)
    """
    # Loop over transverse field annealing schedule
    for field in annealingSchedule:
	# Calculate new coefficient for 1D Ising J
        perpJ = -0.5*trotterSlices*annealingTemperature*np.log(
            np.tanh(field / (trotterSlices*annealingTemperature))
            )
        for step in xrange(mcSteps):
            # Loop over Trotter slices
            for islice in rng.permutation(range(trotterSlices)):
                # Loop over spins
                for ispin in rng.permutation(range(nSpins)):
                    # Attempt to flip this spin
                    if QuantumMetropolisAccept(rng, 
                                               configurations[:, islice], 
                                               configurations[ispin, :],
                                               ispin, 
                                               islice,
                                               neighbors[ispin],
                                               perpJ,
                                               annealingTemperature):
                        configurations[ispin, islice] *= -1
