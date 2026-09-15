import json
from pathlib import Path
import tempfile
from types import SimpleNamespace
import unittest
from unittest.mock import patch
import agent


class PilotTests(unittest.TestCase):
    def test_names_and_path_rules(self):
        rule = {'enabled':True,'match':{'processNames':['Minecraft.exe']}}
        self.assertTrue(agent.match_rule({'name':'MINECRAFT.EXE'}, rule))
        self.assertFalse(agent.match_rule({'name':'notepad.exe'}, rule))
        rule['enabled'] = False
        self.assertFalse(agent.match_rule({'name':'Minecraft.exe'}, rule))

    def test_queue_survives_restart_and_partial_ack(self):
        with tempfile.TemporaryDirectory() as root:
            store = agent.Store(root)
            agent.queue_event(store, 'ProhibitedApplicationDetected', 'student', {})
            agent.queue_event(store, 'WallpaperChanged', 'student', {})
            first = store.batch()[0][0]
            store.db.close()
            store = agent.Store(root)
            self.assertEqual(len(store.batch()),2)
            store.acknowledge([first])
            self.assertEqual(len(store.batch()),1)
            store.db.close()

    def test_failed_or_mismatched_sync_never_drops_queue(self):
        with tempfile.TemporaryDirectory() as root:
            store = agent.Store(root)
            store.set('identity', {'deviceId':'test','deviceSecret':'test'})
            agent.queue_event(store, 'ProhibitedApplicationDetected', 'student', {})
            client = agent.Client({'supabaseUrl':'https://test.supabase.co','edgeFunctionName':'device-sync'})
            with patch.object(client,'post',return_value={'accepted':False,'reEnrollmentRequired':True}):
                with self.assertRaises(RuntimeError):
                    client.sync(store,{})
            self.assertEqual(len(store.batch()),1)
            store.db.close()

    def test_ack_and_unsupported_remote_update(self):
        with tempfile.TemporaryDirectory() as root:
            store = agent.Store(root)
            store.set('identity', {'deviceId':'test','deviceSecret':'test'})
            agent.queue_event(store, 'ProhibitedApplicationDetected', 'student', {})
            client = agent.Client({'supabaseUrl':'https://test.supabase.co','edgeFunctionName':'device-sync'})
            response = {'accepted':True,'jobs':[{'id':'job','type':'agent_update'}]}
            with patch.object(client,'post',return_value=response):
                client.sync(store,{})
                client.sync(store,{})
            self.assertEqual(store.get('handled_jobs'),['job'])
            store.db.close()

    def test_enrollment_is_opt_in(self):
        with tempfile.TemporaryDirectory() as root:
            store = agent.Store(root)
            client = agent.Client({'supabaseUrl':'https://test.supabase.co','edgeFunctionName':'device-sync'})
            with patch.object(client,'post') as request:
                with self.assertRaises(RuntimeError):
                    client.sync(store,{})
                request.assert_not_called()
            store.db.close()

    def test_configuration_offline(self):
        config = json.loads((Path(__file__).parent/'config.json').read_text())
        self.assertFalse(config['enabled'])
        self.assertGreaterEqual(config['syncIntervalSeconds'],1200)
        self.assertNotIn('deviceSecret', config)
        self.assertNotIn('service_role', config)

    def test_process_events_deduplicated_and_stopped(self):
        with tempfile.TemporaryDirectory() as root:
            store = agent.Store(root)
            process = SimpleNamespace(info={'pid':123,'name':'minecraft.exe','exe':'','username':'student','create_time':1})
            policy = {'rules':[{'id':'game','displayName':'Minecraft','enabled':True,'match':{'processNames':['minecraft.exe']}}]}
            with patch('psutil.process_iter', return_value=[process]):
                agent.scan_processes(store, policy)
                agent.scan_processes(store, policy)
            self.assertEqual(len(store.batch()),1)
            with patch('psutil.process_iter', return_value=[]):
                agent.scan_processes(store, policy)
            self.assertEqual([item['payload']['type'] for _,item in store.batch()],
                             ['ProhibitedApplicationDetected','ProhibitedApplicationStopped'])
            store.db.close()

    def test_inventory_only_when_requested(self):
        with tempfile.TemporaryDirectory() as root:
            store = agent.Store(root)
            store.set('identity', {'deviceId':'test','deviceSecret':'test'})
            client = agent.Client({'supabaseUrl':'https://test.supabase.co','edgeFunctionName':'device-sync'})
            with patch('agent.inventory',return_value={'software':[]}) as collect:
                with patch.object(client,'post',return_value={'accepted':True,'jobs':[]}):
                    client.sync(store,{})
                collect.assert_not_called()
                with patch.object(client,'post',return_value={'accepted':True,'jobs':[{'id':'inv','type':'inventory_refresh'}]}):
                    client.sync(store,{})
                collect.assert_called_once()
                self.assertEqual(store.get('pending_inventory'),{'software':[]})
            store.db.close()


if __name__ == '__main__':
    unittest.main()
