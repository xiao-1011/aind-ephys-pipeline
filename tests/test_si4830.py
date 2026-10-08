"""Regression checks run inside the patched image, including both SI consumers."""
import unittest

import numpy as np
import pandas as pd
from spikeinterface.curation import model_based_curation as prediction
from spikeinterface.curation import train_manual_curation as training


class Float32MetricTests(unittest.TestCase):
    def test_overflow_and_existing_missing_values(self):
        limit = np.finfo(np.float32).max
        values = [2.796530216026184e47, -2.796530216026184e47,
                  np.inf, -np.inf, np.nan, limit, -limit, 0.0, 1.5]
        original = pd.DataFrame({"isolation_distance": values}, index=range(40, 49))
        saved = original.copy(deep=True)
        for formatter in (training._format_metric_dataframe, prediction._format_metric_dataframe):
            result = formatter(original)
            self.assertTrue(result.iloc[:5].isna().all().all())
            np.testing.assert_array_equal(result.iloc[5:, 0], np.array(values[5:], dtype="float32"))
            self.assertEqual(result.iloc[:, 0].dtype, np.dtype("float32"))
            self.assertFalse(np.isinf(result.to_numpy()).any())
            pd.testing.assert_index_equal(result.index, original.index)
            pd.testing.assert_frame_equal(original, saved)

    def test_ordinary_inputs_match_previous_formatter_exactly(self):
        original = pd.DataFrame({"snr": [0.0, -1.25, 3.14159265359, 1e20],
                                 "isolation_distance": [1.0, np.nan, np.inf, -np.inf]})
        previous = original.map(lambda value: np.nan if np.isinf(value) else value).astype("float32")
        actual = prediction._format_metric_dataframe(original)
        pd.testing.assert_frame_equal(previous, actual, check_exact=True)

    def test_imputer_accepts_overflow_as_missing(self):
        from sklearn.impute import SimpleImputer

        imputer = SimpleImputer(strategy="median").fit(pd.DataFrame({"metric": [1.0, 2.0, 3.0]}))
        data = prediction._format_metric_dataframe(pd.DataFrame({"metric": [2.8e47, -2.8e47]}))
        np.testing.assert_array_equal(imputer.transform(data), [[2.0], [2.0]])


if __name__ == "__main__":
    unittest.main()
