import numpy as np
import os
import h5py

from few.utils.baseclasses import SchwarzschildEccentric, AmplitudeBase

from pyInterp2DAmplitude import pyAmplitudeGenerator

import os

dir_path = os.path.dirname(os.path.realpath(__file__))


class Interp2DAmplitude(SchwarzschildEccentric, AmplitudeBase):
    """Calculate Teukolsky amplitudes by 2D Cubic Spline interpolation.

    Please see the documentations for
    :class:`few.utils.baseclasses.SchwarzschildEccentric`
    for overall aspects of these models.

    Each mode is setup with a 2D cubic spline interpolant. When the user
    inputs :math:`(p,e)`, the interpolatant determines the corresponding
    amplitudes for each mode in the model.

    args:
        **kwargs (dict, optional): Keyword arguments for the base class:
            :class:`few.utils.baseclasses.SchwarzschildEccentric`. Default is
            {}.

    """

    def __init__(self, **kwargs):

        SchwarzschildEccentric.__init__(self, **kwargs)
        AmplitudeBase.__init__(self, **kwargs)

        few_dir = dir_path + "/../../"

        # check if necessary files are in the few_dir
        file_list = os.listdir(few_dir + "few/files/")

        if "Teuk_amps_a0.0_lmax_10_nmax_30_new.h5" not in file_list:
            raise FileNotFoundError(
                "The file Teuk_amps_a0.0_lmax_10_nmax_30_new.h5 did not open sucessfully. Make sure it is located in the proper directory (Path/to/Installation/few/files/)."
            )

        self.amplitude_generator = pyAmplitudeGenerator(self.lmax, self.nmax, few_dir)

    def get_amplitudes(self, p, e, *args, specific_modes=None, **kwargs):
        """Calculate Teukolsky amplitudes for Schwarzschild eccentric.

        This function takes the inputs the trajectory in :math:`(p,e)` as arrays
        and returns the complex amplitude of all modes to adiabatic order at
        each step of the trajectory.

        args:
            p (1D double numpy.ndarray): Array containing the trajectory for values of
                the semi-latus rectum.
            e (1D double numpy.ndarray): Array containing the trajectory for values of
                the eccentricity.
            l_arr (1D int numpy.ndarray): :math:`l` values to evaluate.
            m_arr (1D int numpy.ndarray): :math:`m` values to evaluate.
            n_arr (1D int numpy.ndarray): :math:`ns` values to evaluate.
            *args (tuple, placeholder): Added to create flexibility when calling different
                amplitude modules. It is not used.
            specific_modes (list, optional): List of tuples for (l, m, n) values
                desired modes. Default is None.
            **kwargs (dict, placeholder): Added to create flexibility when calling different
                amplitude modules. It is not used.

        returns:
            2D array (double): If specific_modes is None, Teukolsky modes in shape (number of trajectory points, number of modes)
            dict: Dictionary with requested modes.


        """

        input_len = len(p)

        if specific_modes is None:
            l_arr, m_arr, n_arr = (
                self.l_arr[self.m_zero_up_mask],
                self.m_arr[self.m_zero_up_mask],
                self.n_arr[self.m_zero_up_mask],
            )
        else:
            l_arr = np.zeros(len(specific_modes), dtype=int)
            m_arr = np.zeros(len(specific_modes), dtype=int)
            n_arr = np.zeros(len(specific_modes), dtype=int)

            inds_revert = []
            for i, (l, m, n) in enumerate(specific_modes):
                l_arr[i] = l
                m_arr[i] = np.abs(m)
                n_arr[i] = n

                if m < 0:
                    inds_revert.append(i)

            inds_revert = np.asarray(inds_revert)

        teuk_modes = self.amplitude_generator(
            p,
            e,
            l_arr.astype(np.int32),
            m_arr.astype(np.int32),
            n_arr.astype(np.int32),
            input_len,
            len(l_arr),
        )

        if specific_modes is None:
            return teuk_modes
        else:
            temp = {}
            for i, lmn in enumerate(specific_modes):
                temp[lmn] = teuk_modes[:, i]
                l, m, n = lmn
                if m < 0:
                    temp[lmn] = np.conj(temp[lmn])

            return temp
